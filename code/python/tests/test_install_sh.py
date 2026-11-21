"""`code/install.sh` platform table and exit codes, exercised through a fake uname.

The installer's contract is its platform table: every supported (os, arch) maps
to an asset the release carries, and unsupported ones exit 2 *before* calling
curl. `--dry-run` resolves the table without downloading, so the shell-level
self-check needs no network.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / "code" / "install.sh"

RELEASE_PLATFORMS = {
    ("Linux", "x86_64"): "liwenjson-linux-x86_64",
    ("Linux", "amd64"): "liwenjson-linux-x86_64",
    ("Linux", "aarch64"): "liwenjson-linux-arm64",
    ("Linux", "arm64"): "liwenjson-linux-arm64",
    ("Darwin", "arm64"): "liwenjson-macos-arm64",
    ("Darwin", "aarch64"): "liwenjson-macos-arm64",
    ("MINGW64_NT-10.0", "x86_64"): "liwenjson-windows-x86_64.exe",
}

REFUSED = [
    ("Darwin", "x86_64", "Intel macOS"),
    ("MINGW64_NT-10.0", "arm64", "Windows arm64"),
    ("FreeBSD", "amd64", "unsupported operating system"),
    ("Linux", "riscv64", "unsupported architecture"),
]


# `install.sh` is a POSIX shell script: the tests write fake `uname`/`curl`
# shims, chmod them, and run the script under `sh`. Windows has neither, and the
# platform is refused by the script itself, so the class is skipped there.
@unittest.skipIf(os.name != "posix", "install.sh is a POSIX shell script")
class InstallScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work = Path(self._tmp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.curl_log = self.work / "curl.log"
        self._write(self.bin / "uname", """#!/bin/sh
case "$1" in
  -s) printf '%s\\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\\n' "$FAKE_UNAME_M" ;;
  *) printf '%s\\n' "$FAKE_UNAME_S" ;;
esac
""")
        self._write(self.bin / "curl", """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_CURL_LOG"
exit 1
""")

    def _write(self, path: Path, text: str) -> None:
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def run_install(
        self,
        os_name: str,
        machine: str,
        *args: str,
        version: str = "v0.0.0-test",
        dir_name: str = "dest",
    ) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env.update(
            PATH=f"{self.bin}{os.pathsep}{env.get('PATH', '')}",
            FAKE_UNAME_S=os_name,
            FAKE_UNAME_M=machine,
            FAKE_CURL_LOG=str(self.curl_log),
            LIWENJSON_DIR=str(self.work / dir_name),
        )
        if version:
            env["LIWENJSON_VERSION"] = version
        return subprocess.run(
            ["sh", str(INSTALLER), *args],
            env=env,
            cwd=str(self.work),
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_release_platforms_resolve_to_released_assets(self) -> None:
        for (os_name, machine), asset in RELEASE_PLATFORMS.items():
            with self.subTest(os=os_name, machine=machine):
                proc = self.run_install(os_name, machine, "--dry-run")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn(asset, proc.stdout)
                # A dry run must not touch the network.
                self.assertFalse(self.curl_log.exists())

    def test_unsupported_platforms_exit_2_before_downloading(self) -> None:
        for os_name, machine, needle in REFUSED:
            with self.subTest(os=os_name, machine=machine):
                proc = self.run_install(os_name, machine, "--dry-run")
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
                self.assertIn(needle, proc.stderr)
                self.assertFalse(self.curl_log.exists())

    def test_no_windows_arm64_asset_is_claimed(self) -> None:
        proc = self.run_install("MINGW64_NT-10.0", "arm64", "--dry-run")
        self.assertEqual(proc.returncode, 2)
        self.assertNotIn("windows-arm64", proc.stdout + proc.stderr)
        proc = self.run_install("MINGW64_NT-10.0", "x86_64", "--dry-run")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("liwenjson-windows-x86_64.exe", proc.stdout)

    def test_dry_run_creates_nothing(self) -> None:
        proc = self.run_install("Linux", "x86_64", "--dry-run")
        self.assertEqual(proc.returncode, 0)
        self.assertFalse((self.work / "dest").exists())

    def test_download_failure_exits_1_and_installs_nothing(self) -> None:
        proc = self.run_install("Linux", "x86_64")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("download failed", proc.stderr)
        self.assertTrue(self.curl_log.exists())
        self.assertFalse((self.work / "dest" / "liwenjson").exists())

    def test_help_exits_0(self) -> None:
        proc = self.run_install("Linux", "x86_64", "--help")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("usage", proc.stdout.lower())

    def test_unknown_argument_is_a_usage_error(self) -> None:
        proc = self.run_install("Linux", "x86_64", "--nope")
        self.assertEqual(proc.returncode, 2)

    def test_missing_version_without_network_is_an_error(self) -> None:
        # With no --dry-run the latest tag is fetched; the fake curl fails, so
        # the script must report that instead of installing something unnamed.
        proc = self.run_install("Linux", "x86_64", version="")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("latest release", proc.stderr)


if __name__ == "__main__":
    unittest.main()
