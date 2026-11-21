#!/usr/bin/env python3
"""The three Windows I/O invariants a Linux CI cannot see.

The CLI is a byte-oriented tool, and on Windows every one of those bytes crosses
a C runtime that would rather translate them:

- stdio opens in *text* mode, so every `\\n` written becomes `\\r\\n` and every
  `0x1A` read is taken for end-of-file (which truncates a document, silently,
  with a legal-JSON result);
- `fopen` reads a path in the ANSI code page, so a file name outside ASCII is
  reported as missing;
- Win32 refuses a path past 260 characters unless it carries `\\\\?\\`.

None of that exists on Linux or macOS, so the gates there stayed green while the
Windows report was red on 40 assertions. This script is the small gate that runs
on every platform and on Windows checks the fixes: fed the same arguments it
must fail on an old binary and pass on the current one.

It is deliberately not a port of the Windows package's `win_gate.py` (191
assertions, including a fixture-driven CLI smoke): this is the handful of
assertions that belong in CI, cheap enough to run next to the build.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

FAILURES: list[str] = []
PASSED = 0


def run(cli: Path, args: list[str], stdin: bytes = b"", cwd: Path | None = None):
    proc = subprocess.run(
        [str(cli), *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=None if cwd is None else str(cwd),
    )
    return proc.returncode, proc.stdout, proc.stderr


def ok(name: str, extra: str = "") -> None:
    global PASSED
    PASSED += 1
    print(f"ok   {name:<52} {extra}".rstrip(), flush=True)


def fail(name: str, detail: str) -> None:
    FAILURES.append(f"{name}: {detail}")
    print(f"FAIL {name:<52}", flush=True)
    for line in detail.splitlines():
        print(f"     {line}", flush=True)


def skip(name: str, why: str) -> None:
    print(f"skip {name:<52} {why}", flush=True)


def check(name: str, cli: Path, args: list[str], want: bytes, stdin: bytes = b"") -> None:
    rc, out, err = run(cli, args, stdin)
    if rc == 0 and out == want:
        ok(name, f"rc=0 out={out!r}")
        return
    fail(name, f"rc={rc} want={want!r} got={out!r} err={err[:200]!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=None, help="path to the liwenjson binary")
    args = parser.parse_args()

    cli = Path(args.cli or default_binary()).resolve()
    if not cli.is_file():
        print(f"liwenjson not found: {cli}", file=sys.stderr)
        return 2
    print(f"cli: {cli}")
    print(f"platform: {sys.platform}\n")

    # 1. stdio is binary in the write direction: no CR anywhere, and the output
    #    still ends with the LF every other platform writes.
    rc, out, err = run(cli, ["--version"])
    if rc != 0:
        fail("stdout is binary (write side)", f"--version exited {rc}")
    elif b"\r" in out:
        fail(
            "stdout is binary (write side)",
            f"--version wrote a CR byte: {out!r}\n"
            "     the stream is in text mode; call _setmode(_O_BINARY) on fd 1",
        )
    elif not out.endswith(b"\n"):
        fail("stdout is binary (write side)", f"--version does not end with LF: {out!r}")
    else:
        ok("stdout is binary (write side)", f"{out!r}")

    # The same, on the repair path (a document goes in, a document comes out).
    check("repaired output is LF-only", cli, [], b'{"a":1}\n', b'{"a":1,}')

    # 2. stdio is binary in the read direction: 0x1A is data. In text mode it is
    #    read as end-of-file and the document is truncated to `{"a":"x"}` -- a
    #    legal document, so nothing downstream notices.
    check(
        "0x1A on stdin is data, not end of file",
        cli,
        [],
        b'{"a":"x\\u001ay"}\n',
        b'{"a":"x\x1ay"}',
    )

    # 3. A path outside ASCII, with a space in it: `fopen` would read those
    #    bytes in the ANSI code page and report ENOENT.
    with tempfile.TemporaryDirectory() as tmp:
        holder = Path(tmp) / "带 空格 目录"
        holder.mkdir()
        document = holder / "文 档.json"
        document.write_bytes(b'{"a":1,}')
        check("non-ASCII absolute path", cli, [str(document)], b'{"a":1}\n')

    # The relative form goes through the same call, with no drive or leading
    # separator to anchor it: it must be resolved against the current directory.
    with tempfile.TemporaryDirectory() as tmp:
        holder = Path(tmp) / "带 空格 目录"
        holder.mkdir()
        document = holder / "文 档.json"
        document.write_bytes(b'{"a":1,}')
        rc, out, err = run(cli, ["文 档.json"], cwd=holder)
        if rc == 0 and out == b'{"a":1}\n':
            ok("non-ASCII relative path", "cwd=<带 空格 目录>")
        else:
            fail("non-ASCII relative path", f"rc={rc} out={out!r} err={err[:200]!r}")

    # 4. A path past 260 characters. Win32 needs the `\\?\` prefix to go past
    #    MAX_PATH, and the product adds it for absolute paths; the test has to
    #    use it to build the tree, which is exactly what WinError 3 teaches.
    long_ok = check_long_path(cli)
    if not long_ok:
        skip("long absolute path (>260 chars)", "this platform refused to build the tree")

    # 5. CRLF frames for `--batch`: Windows writes text files with `\r\n`, and a
    #    trailing `\r` must not turn into an error line.
    rc, out, err = run(
        cli,
        ["--batch"],
        b'{"id":"a","input":"[1,2"}\r\n{"id":"b","input":"{}"}\r\n',
    )
    lines = [line for line in out.split(b"\n") if line.strip()]
    if rc != 0:
        fail("--batch accepts CRLF frames", f"exit {rc}: {err[:200]!r}")
    elif len(lines) != 2:
        fail("--batch accepts CRLF frames", f"want 2 result lines, got {len(lines)}: {out!r}")
    elif b'"rc":0' not in lines[0] or b'"rc":0' not in lines[1]:
        fail("--batch accepts CRLF frames", f"{lines!r}")
    elif b"E060" in out:
        fail("--batch accepts CRLF frames", f"a CRLF frame produced E060: {out!r}")
    else:
        ok("--batch accepts CRLF frames", "2 lines, both rc=0")

    print()
    if FAILURES:
        print(f"win_io_check: FAILED — {len(FAILURES)} of {PASSED + len(FAILURES)} checks")
        for line in FAILURES:
            print("  " + line)
        return 1
    print(f"win_io_check: OK — {PASSED} checks passed.")
    return 0


def extended(path: Path) -> str:
    """The `\\\\?\\` form Win32 needs to go past MAX_PATH (Windows only)."""
    raw = str(path)
    if sys.platform != "win32" or raw.startswith("\\\\?\\"):
        return raw
    return "\\\\?\\" + raw


def check_long_path(cli: Path) -> bool:
    """Read a document whose absolute path is past 260 characters."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "long"
        deep = root
        for i in range(12):
            deep = deep / ("d" * 20 + str(i))
        document = deep / "long.json"
        try:
            os.makedirs(extended(deep), exist_ok=True)
            with open(extended(document), "wb") as handle:
                handle.write(b'{"a":1,}')
        except OSError as exc:
            print(f"     could not build a long path here: {exc}")
            return False
        try:
            rc, out, err = run(cli, [str(document)])
            if rc == 0 and out == b'{"a":1}\n':
                ok("long absolute path (>260 chars)", f"len={len(str(document))}")
                return True
            fail(
                "long absolute path (>260 chars)",
                f"len={len(str(document))} rc={rc} out={out!r} err={err[:200]!r}",
            )
            return True
        finally:
            shutil_rmtree(extended(root))


def shutil_rmtree(path: str) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


def default_binary() -> str:
    """The release build this repository produces (any platform).

    MoonBit's native backend names the artifact `liwenjson.exe` even on a
    Unix host, so `--cli` is only a convenience: both names are tried.
    """
    directory = (
        Path(__file__).resolve().parent.parent
        / "_build" / "native" / "release" / "build" / "cmd" / "liwenjson"
    )
    for name in ("liwenjson", "liwenjson.exe"):
        candidate = directory / name
        if candidate.is_file():
            return str(candidate)
    return str(directory / "liwenjson")


if __name__ == "__main__":
    raise SystemExit(main())
