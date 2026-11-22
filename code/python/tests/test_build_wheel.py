"""P2-06: `build_wheel.sh` must not package a binary for the wrong target.

The audit (`marks/1120优化.md` §5 P2-06) built a wheel on macOS arm64 with
`--from-local linux-x86_64` and got a Mach-O arm64 file in
`liwenjson/bin/linux-x86_64/`. A checksum only proves the copy: the wheel
installs and the first call dies with `Exec format error`. These tests pin the
three gates that stop it:

  * `--from-local` must name the host platform, and a local build is a
    single-platform test wheel, never a four-platform release wheel;
  * every asset (local, `--from-dir`, downloaded) must be the container format
    and architecture its platform name claims;
  * the host-platform binary must actually start after it is staged.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "code/python/build_wheel.sh"
NATIVE = ROOT / "code/_build/native/release/build/cmd/liwenjson/liwenjson.exe"
RELEASE_PLATFORMS = ("linux-x86_64", "linux-arm64", "macos-arm64", "windows-x86_64")


def host_key() -> str:
    system = sys.platform
    machine = platform.machine().lower()
    if system == "darwin" and machine in ("arm64", "aarch64"):
        return "macos-arm64"
    if system.startswith("linux") and machine in ("x86_64", "amd64"):
        return "linux-x86_64"
    if system.startswith("linux") and machine in ("aarch64", "arm64"):
        return "linux-arm64"
    return ""


def asset_name(platform_key: str) -> str:
    return "liwenjson-windows-x86_64.exe" if platform_key.startswith("windows-") else "liwenjson-" + platform_key


def elf(machine: int, bits: int = 2) -> bytes:
    header = b"\x7fELF" + bytes([bits, 1, 1]) + b"\x00" * 9
    header += struct.pack("<H", 2) + struct.pack("<H", machine) + b"\x00" * 48
    return header + b"\x00" * 4096


def macho(cputype: int) -> bytes:
    header = struct.pack("<I", 0xFEEDFACF) + struct.pack("<I", cputype) + b"\x00" * 24
    return header + b"\x00" * 4096


def pe(machine: int) -> bytes:
    stub = bytearray(b"MZ" + b"\x00" * 0x3E)
    struct.pack_into("<I", stub, 0x3C, 0x40)
    stub += b"PE\x00\x00" + struct.pack("<H", machine) + b"\x00" * 64
    return bytes(stub) + b"\x00" * 4096


def valid_binary(platform_key: str) -> bytes:
    if platform_key == "linux-x86_64":
        return elf(62)
    if platform_key == "linux-arm64":
        return elf(183)
    if platform_key == "macos-arm64":
        return macho(0x0100000C)
    return pe(0x8664)


# The wheel is built by `build_wheel.sh`, which downloads the release binaries
# with curl and checks them against `SHA256SUMS`; none of that exists on
# Windows (and the wheel has no Windows-named output to look for), so the class
# is skipped there instead of failing for a reason it does not test.
@unittest.skipIf(os.name != "posix", "the wheel is built by a POSIX shell script")
class BuildWheelTests(unittest.TestCase):
    def run_wheel(self, *args: str, timeout: float = 90.0) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def assets_dir(self, files: dict[str, bytes]) -> tempfile.TemporaryDirectory:
        tmp = tempfile.TemporaryDirectory()
        directory = Path(tmp.name)
        lines = []
        for name, data in files.items():
            path = directory / name
            path.write_bytes(data)
            path.chmod(0o755)
            lines.append(hashlib.sha256(data).hexdigest() + "  " + name)
        (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
        return tmp

    def test_unknown_platform_key_is_refused(self) -> None:
        result = self.run_wheel("--platforms", "linux-riscv64", "--from-dir", "/nonexistent")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unknown platform key: linux-riscv64", result.stderr)

    def test_from_local_must_name_the_host(self) -> None:
        host = host_key()
        if not host:
            self.skipTest("this host is not a release platform")
        other = next(key for key in RELEASE_PLATFORMS if key != host)
        result = self.run_wheel("--from-local", other, "--platforms", other)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(f"is not this host ({host})", result.stderr)
        self.assertIn("Refusing to copy it into another platform's directory", result.stderr)

    def test_from_local_cannot_claim_multiple_platforms(self) -> None:
        host = host_key()
        if not host:
            self.skipTest("this host is not a release platform")
        other = next(key for key in RELEASE_PLATFORMS if key != host)
        result = self.run_wheel("--from-local", host, "--platforms", f"{host} {other}")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("single-platform test wheel", result.stderr)

    def test_from_dir_rejects_a_non_elf_for_linux(self) -> None:
        with self.assets_dir({"liwenjson-linux-x86_64": b"this is not a binary"}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", "linux-x86_64",
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("is not an ELF binary", result.stderr)

    def test_from_dir_rejects_the_wrong_elf_architecture(self) -> None:
        # An arm64 ELF named as the x86_64 asset: every checksum is correct.
        with self.assets_dir({"liwenjson-linux-x86_64": elf(183)}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", "linux-x86_64",
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("ELF machine 0xb7, not 0x3e (linux-x86_64)", result.stderr)

    def test_from_dir_rejects_the_wrong_macho_architecture(self) -> None:
        with self.assets_dir({"liwenjson-macos-arm64": macho(0x01000007)}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", "macos-arm64",
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Mach-O cputype", result.stderr)

    def test_from_dir_rejects_a_wrong_pe_machine(self) -> None:
        with self.assets_dir({"liwenjson-windows-x86_64.exe": pe(0xAA64)}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", "windows-x86_64",
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("is PE machine 0xaa64, not 0x8664", result.stderr)

    def test_from_dir_fails_when_sha256sums_omits_an_asset(self) -> None:
        with self.assets_dir({"liwenjson-linux-x86_64": elf(62)}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", "linux-arm64",
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("missing asset", result.stderr)

    def test_the_staged_host_binary_must_start(self) -> None:
        host = host_key()
        if not host:
            self.skipTest("this host is not a release platform")
        # A structurally valid header for the host is not enough: it has to run.
        with self.assets_dir({asset_name(host): valid_binary(host)}) as assets:
            result = self.run_wheel("--from-dir", assets, "--platforms", host,
                                    "--out", os.path.join(assets, "out"))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("did not start", result.stderr)

    def test_local_build_is_a_single_platform_wheel_that_starts(self) -> None:
        host = host_key()
        if not host:
            self.skipTest("this host is not a release platform")
        if not NATIVE.is_file():
            self.skipTest("the native CLI has not been built")
        with tempfile.TemporaryDirectory() as out:
            result = self.run_wheel("--from-local", host, "--platforms", host, "--out", out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("started : liwenjson ", result.stdout)
            wheels = list(Path(out).glob("liwenjson-*.whl"))
            self.assertEqual(len(wheels), 1, "expected exactly one wheel")
            import zipfile

            names = zipfile.ZipFile(wheels[0]).namelist()
            binaries = [name for name in names if "/bin/" in name]
            self.assertEqual(binaries, [f"liwenjson/bin/{host}/liwenjson"], binaries)
            # Exercise the installed console scripts, not the source module or
            # a CLI supplied by the developer's PATH / LIWENJSON_BIN.
            environment = Path(out) / "venv"
            subprocess.run([sys.executable, "-m", "venv", str(environment)],
                           check=True, capture_output=True, timeout=60)
            scripts = environment / "bin"
            subprocess.run([str(scripts / "python"), "-m", "pip", "install",
                            "--no-index", "--no-deps", str(wheels[0])],
                           check=True, capture_output=True, timeout=60)
            env = os.environ.copy()
            for name in ("LIWENJSON_BIN", "PYTHONPATH", "PYTHONHOME"):
                env.pop(name, None)
            env["PATH"] = str(scripts) + os.pathsep + os.defpath

            def run(args: list[str], input: str = "") -> str:
                return subprocess.run(args, input=input, env=env, cwd=out,
                                      capture_output=True, text=True, check=True,
                                      timeout=15).stdout

            from version import engine_version

            self.assertEqual(run(["liwenjson", "--version"]).strip(),
                             f"liwenjson {engine_version()}")
            self.assertEqual(run(["liwenjson-mcp", "--version"]).strip(),
                             f"liwenjson {engine_version()}")
            config = json.loads(run(["liwenjson-mcp", "--print-config=json"]))
            server = config["mcpServers"]["liwenjson"]
            self.assertEqual(server, {"command": "liwenjson", "args": ["mcp"]})
            configured = [server["command"], *server["args"]]
            self.assertEqual(json.loads(run([*configured, "--print-config=json"])), config)
            requests = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                            "clientInfo": {"name": "wheel-test", "version": "1"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            ]
            replies = [json.loads(line) for line in run(
                configured, "".join(json.dumps(request) + "\n" for request in requests)
            ).splitlines()]
            by_id = {reply.get("id"): reply for reply in replies}
            self.assertEqual(by_id[1]["result"]["protocolVersion"], "2025-06-18")
            self.assertIn("liwenjson_gate", {tool["name"] for tool in by_id[2]["result"]["tools"]})
            # Client() now finds the console script too; it must forward serve
            # to the bundled engine rather than recursively execing itself.
            self.assertEqual(run([str(scripts / "python"), "-c",
                                  "from liwenjson import repair; print(repair(\"{'a':1,}\")[\"text\"])"]).strip(),
                             '{"a":1}')

    def test_help_documents_the_host_contract(self) -> None:
        result = self.run_wheel("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--from-local", result.stdout)
        self.assertIn("single-platform test", result.stdout)
        self.assertIn("wheel for the host", result.stdout)


if __name__ == "__main__":
    unittest.main()
