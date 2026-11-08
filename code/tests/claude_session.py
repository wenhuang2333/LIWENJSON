#!/usr/bin/env python3
"""Drive an interactive `claude` session through a pty and save the transcript.

    python3 test/claude_session.py --script <script.json> [--out <dir>]

The audit asked for at least one mandatory host integration verified against a
real client session (marks/迭代.md §8.3). This is that driver: it spawns the
real Claude Code terminal UI on a pty, waits for the prompt, types a message,
waits for the turn to end, and captures every byte the terminal printed.

It is not part of CI -- it needs a logged-in `claude` and a model API -- but the
transcript it writes is evidence, and `test/claude_session_check.py` reads that
transcript.

A script file is a JSON list of steps:
    [{"send": "hello", "wait": 60}, {"send": "/exit", "wait": 10}]
Each step types `send` (literal, then Enter) and then waits up to `wait`
seconds for the UI to become idle again.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path

# The Claude Code TUI draws a box with the input line near the bottom. These are
# the shapes it uses to say "I am ready" and "I am working"; they are matched
# loosely on purpose, because a themed UI may change the wording and the driver
# should still work.
def squash(text: str) -> str:
    """Drop all whitespace.

    Claude Code's terminal UI positions the cursor to draw each fragment, so a
    line like `Enter to confirm` arrives as separate runs with no spaces
    between them once the escape sequences are stripped. Matching on a
    whitespace-free copy is the only stable way to read its prompts.
    """
    return re.sub(r"\s+", "", text)


IDLE_MARKERS = [
    "? for shortcuts",
    "esc to interrupt",
    "bypass permissions",
]
BUSY_MARKERS = [
    "esc to interrupt",
    "Running…",
    "Thinking…",
    "· working",
]


class Session:
    def __init__(self, argv: list[str], cwd: str, cols: int = 140, rows: int = 48):
        self.buf = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            os.chdir(cwd)
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLUMNS"] = str(cols)
            os.environ["LINES"] = str(rows)
            os.execvp(argv[0], argv)
        # Parent: size the window, then keep it non-blocking.
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        flags = fcntl.fcntl(self.fd, fcntl.F_GETFL)
        fcntl.fcntl(self.fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    def read(self, timeout: float = 0.5) -> bytes:
        try:
            ready, _, _ = select.select([self.fd], [], [], timeout)
        except (OSError, ValueError):
            return b""
        if not ready:
            return b""
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            return b""
        if data:
            self.buf.extend(data)
        return data

    def text(self) -> str:
        # Strip ANSI sequences so the transcript is readable and greppable.
        raw = self.buf.decode("utf-8", "replace")
        raw = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw)
        raw = re.sub(r"\x1b\][^\x07]*\x07", "", raw)
        raw = re.sub(r"\x1b[()][A-Z0-9]", "", raw)
        raw = re.sub(r"[\x00-\x08\x0b-\x1f]", "", raw)
        return raw

    def wait_for(self, needles: list[str], timeout: float) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.read(0.4)
            if any(n in self.text() for n in needles):
                return True
        return False

    def wait_idle(self, timeout: float) -> bool:
        """Wait until the UI shows the input prompt again.

        Claude Code asks two first-run questions before the composer appears
        (trust this folder; accept the bypass-permissions warning). Both are
        answered here by picking the option whose text says yes: the trust
        dialog puts "Yes" first and the bypass warning puts it second, so
        "press 1" is not a rule that survives both.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.read(0.5)
            tail = squash(self.text()[-4000:])
            if "Entertoconfirm" in tail or "Esctocancel" in tail:
                if self.answer_confirm(tail):
                    continue
            if "bypasspermissions" in tail or "?forshortcuts" in tail:
                # Give it a moment: the marker can appear before the turn ends.
                self.read(0.8)
                return True
        return False

    def answer_confirm(self, squashed_tail: str) -> bool:
        """Press the affirmative option of a numbered confirmation dialog."""
        options = re.findall(r"(?:❯)?(\d+)\.(Yes[^0-9]*|Iaccept[^0-9]*)", squashed_tail)
        for number, _label in options:
            os.write(self.fd, number.encode())
            time.sleep(0.25)
            os.write(self.fd, b"\r")
            self.read(0.6)
            return True
        # No affirmative option: accept the default with Enter.
        os.write(self.fd, b"\r")
        self.read(0.6)
        return True

    def send(self, text: str) -> None:
        os.write(self.fd, text.encode("utf-8"))
        time.sleep(0.15)
        os.write(self.fd, b"\r")

    def close(self) -> None:
        try:
            os.write(self.fd, b"\x03")
            time.sleep(0.3)
            os.kill(self.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cwd", default="/tmp/ij-e2e")
    ap.add_argument("--script", required=True, help="a JSON list of steps")
    ap.add_argument("--out", default=None, help="directory for the transcript")
    ap.add_argument("--start-timeout", type=float, default=120)
    args = ap.parse_args()

    out = Path(args.out or os.path.join(args.cwd, "session"))
    out.mkdir(parents=True, exist_ok=True)
    steps = json.loads(Path(args.script).read_text(encoding="utf-8"))

    session = Session(["claude", "--dangerously-skip-permissions"], args.cwd)
    try:
        if not session.wait_idle(args.start_timeout):
            print("the UI never became idle at startup", file=sys.stderr)
            (out / "startup.txt").write_text(session.text(), encoding="utf-8")
            return 1
        for i, step in enumerate(steps):
            (out / f"before-step-{i}.txt").write_text(session.text(), encoding="utf-8")
            session.send(step["send"])
            ok = session.wait_idle(step.get("wait", 120))
            (out / f"step-{i}.txt").write_text(session.text(), encoding="utf-8")
            print(f"step {i}: {'ok' if ok else 'timeout'}  {step['send'][:60]!r}", flush=True)
            if not ok:
                break
    finally:
        (out / "transcript.txt").write_text(session.text(), encoding="utf-8")
        session.close()
    print("transcript:", out / "transcript.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
