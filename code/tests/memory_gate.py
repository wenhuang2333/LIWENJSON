#!/usr/bin/env python3
"""Peak-memory gate: the ratios the documents quote are the ratios this build has.

    python3 code/tests/memory_gate.py --cli <liwenjson binary> [--json]

Why this exists
---------------

`docs/MEMORY.md` is a *report*: it prints what the machine measured, and a
report that is only ever printed is a report that drifts. The repository has
been through that once already -- a memory figure in a document was quoted for
several releases after the code that produced it had changed, and nothing
noticed, because nothing compared the two.

So this file is the gate. It measures the same shapes the report does, compares
each one against a ceiling recorded *here*, and fails when a shape grows past
it. The ceilings are the measured value plus a margin, not an aspiration: a
number nobody can hit is not a gate, it is a wish.

What is measured, and what is deliberately not
----------------------------------------------

Peak RSS is the process high-water mark, which is what a user feels. It is
dominated by the runtime's baseline, so the gate subtracts a baseline measured
from the same binary on the smallest possible document, and reports the
*marginal* cost per byte of input. Without that subtraction a 1 MB input would
be compared against a 7 MB floor and the ratio would be meaningless.

Two things this gate does not do, and says so rather than hiding them:

* it does not measure a "no-tree" mode, because there is not one. The
  measured ratios are for a parse that builds the value;
* it does not gate the `repair` ratios for containers as tightly as the
  `--check` ratios, because rendering holds the tree and the output at the same
  time and that peak is a property of the two together.

The design for a mode that avoids the tree is written up in `docs/NOTREE.md`;
when it exists, its arm belongs here.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI = os.path.join(
    HERE, "..", "_build", "native", "release", "build", "cmd", "liwenjson", "liwenjson.exe"
)

# Elements per generated document. Large enough that the runtime baseline is a
# small part of the total, small enough that the gate runs in seconds.
N = 200_000

# shape -> (generator, ceiling on marginal bytes per input byte for --check)
#
# The ceilings are what this build measures, rounded up. A shape that grows
# past its ceiling is a regression: either a walk started retaining something
# it used to drop, or a container started over-allocating again.
SHAPES = {
    "ints": (lambda n: "[" + ",".join(str(i) for i in range(n)) + "]", 6.5),
    "floats": (lambda n: "[" + ",".join(f"{i}.5" for i in range(n)) + "]", 9.0),
    "strings": (lambda n: "[" + ",".join('"xy"' for _ in range(n)) + "]", 8.0),
    "one_key_objects": (lambda n: "[" + ",".join('{"a":1}' for _ in range(n)) + "]", 27.0),
    "one_elem_arrays": (lambda n: "[" + ",".join("[1]" for _ in range(n)) + "]", 27.0),
    "nested_arrays": (lambda n: "[" + ",".join("[[1]]" for _ in range(n)) + "]", 30.0),
    "empty_objects": (lambda n: "[" + ",".join("{}" for _ in range(n)) + "]", 29.0),
}


def peak_rss_mb(binary: str, args: list[str], data: bytes) -> float | None:
    """Peak RSS of one child process, in MiB, or `None` when unmeasurable.

    POSIX reports the high-water mark of the child that just exited through
    `wait4`, which needs no wrapper binary. Windows has no `fork`/`wait4`; the
    same number is read from `GetProcessMemoryInfo`, on a handle opened while
    the child is still running (the handle keeps the process object alive after
    it exits, so the peak survives). The child's output is discarded either
    way: this measures memory, not results.
    """
    if sys.platform == "win32":
        return _peak_rss_mb_windows(binary, args, data)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - child
        try:
            with open(os.devnull, "w") as devnull:
                os.dup2(devnull.fileno(), 1)
                os.dup2(devnull.fileno(), 2)
            subprocess.run([binary, *args], input=data, capture_output=True)
        finally:
            os._exit(0)
    _, _, usage = os.wait4(pid, 0)
    # macOS reports bytes, Linux reports KiB. Both are handled by asking the
    # platform rather than assuming.
    if sys.platform == "darwin":
        return usage.ru_maxrss / (1024 * 1024)
    return usage.ru_maxrss / 1024


def _peak_rss_mb_windows(binary: str, args: list[str], data: bytes) -> float | None:
    """Peak working set of one child on Windows, in MiB.

    Returns `None` instead of raising when the platform refuses to report it:
    the caller turns that into a SKIP, because a gate that cannot measure must
    not pretend to have passed.
    """
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    # `PROCESS_QUERY_LIMITED_INFORMATION` is enough for the counters and is what
    # a non-elevated process is allowed to ask for about its own child.
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        proc = subprocess.Popen(
            [binary, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, proc.pid)
        if not handle:
            proc.communicate(data)
            return None
        try:
            proc.communicate(data)
            counters = Counters()
            counters.cb = ctypes.sizeof(counters)
            if not psapi.GetProcessMemoryInfo(
                handle, ctypes.byref(counters), counters.cb
            ):
                return None
            return counters.PeakWorkingSetSize / (1024 * 1024)
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=DEFAULT_CLI)
    parser.add_argument("--json", action="store_true", help="print the measurements as JSON")
    parser.add_argument(
        "--scale",
        type=float,
        default=1.0,
        help="multiply the element count (for a longer local run)",
    )
    args = parser.parse_args()

    binary = os.path.abspath(args.cli)
    if not os.path.isfile(binary):
        print(f"liwenjson not found: {binary}", file=sys.stderr)
        return 2

    n = int(N * args.scale)
    baseline = peak_rss_mb(binary, ["--check"], b"{}")
    if baseline is None:
        print(
            "memory_gate: SKIP — this platform does not report a child's peak "
            "working set, so the ceilings cannot be checked here.",
            file=sys.stderr,
        )
        return 2

    rows = []
    failures = []
    for name, (gen, ceiling) in SHAPES.items():
        raw = gen(n).encode()
        mb = len(raw) / (1024 * 1024)
        measured = peak_rss_mb(binary, ["--check"], raw)
        if measured is None:
            print(
                "memory_gate: SKIP — the peak working set stopped being "
                "readable mid-run.",
                file=sys.stderr,
            )
            return 2
        marginal = measured - baseline
        ratio = marginal / mb
        ok = ratio <= ceiling
        rows.append(
            {
                "shape": name,
                "input_mb": round(mb, 3),
                "marginal_mb": round(marginal, 2),
                "ratio": round(ratio, 2),
                "ceiling": ceiling,
                "ok": ok,
            }
        )
        if not ok:
            failures.append(
                f"{name}: {ratio:.2f}x exceeds the recorded ceiling {ceiling:.2f}x "
                f"({marginal:.1f} MiB for {mb:.2f} MiB of input)"
            )

    if args.json:
        print(json.dumps({"baseline_mb": round(baseline, 2), "rows": rows}, indent=2))
    else:
        print(f"process baseline: {baseline:.1f} MiB\n")
        print(f"{'shape':18}{'input':>9}{'marginal':>10}{'ratio':>8}{'ceiling':>9}  ")
        for row in rows:
            mark = "ok" if row["ok"] else "FAIL"
            print(
                f"{row['shape']:18}{row['input_mb']:8.2f}M{row['marginal_mb']:9.1f}M"
                f"{row['ratio']:7.2f}x{row['ceiling']:8.2f}x  {mark}"
            )

    if failures:
        print("\nmemory_gate: FAILED", file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        print(
            "\nThe ratios the documents quote come from docs/MEMORY.md; this gate is what\n"
            "keeps them from drifting. Fix the allocation, or re-baseline the ceiling\n"
            "deliberately and say why in the commit message.",
            file=sys.stderr,
        )
        return 1

    print("\nmemory_gate: OK — every shape is within its recorded ceiling.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
