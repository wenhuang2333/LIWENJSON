#!/usr/bin/env python3
"""Replay the recorded PreToolUse payloads through the gate hook.

The audit asked for at least one *mandatory* host integration (marks/迭代.md
§8.3). `code/tests/mcp_client_replay.py` covers the advisory MCP path; this
covers the enforced one: a `PreToolUse` hook that runs the gate on every Bash
call and denies the call when the declaration is not satisfied.

The transcripts this replays are real. `test/claude-e2e/` holds:

  * `hook-deny.jsonl`  — a real Claude Code 2.1.145 session in which the model
    ran `touch pwned.txt` and the hook refused it; the file was never created;
  * `hook-allow.jsonl` — the same session shape with `echo read-only-ok`, which
    passed and ran;
  * the hook script, its declarations and the settings that wired it up.

This gate feeds the recorded payloads to that exact script and checks the
decision. It needs no model, so it runs in CI; it is what stops the wiring from
rotting between recordings.

    python3 code/tests/hook_replay.py [--bin path-to-interjson]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
E2E = ROOT / "code" / "tests" / "claude-e2e"
DEFAULT_BIN = ROOT / "code/_build/native/release/build/cmd/interjson/interjson.exe"


def tools_used(transcript: Path) -> list[str]:
    """The tools a recorded session called, in order."""
    out: list[str] = []
    for line in transcript.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") != "assistant":
            continue
        for part in event.get("message", {}).get("content", []):
            if part.get("type") == "tool_use":
                out.append(part.get("name"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=os.environ.get("INTERJSON_BIN", str(DEFAULT_BIN)))
    ap.add_argument("--dir", default=str(E2E))
    args = ap.parse_args()

    e2e = Path(args.dir)
    script = e2e / ".claude" / "hooks" / "interjson-gate.sh"
    for path in (script, e2e / "payload-deny.json", e2e / "payload-allow.json"):
        if not path.exists():
            print(f"missing {path}", file=sys.stderr)
            return 2

    env = dict(os.environ)
    env["INTERJSON_BIN"] = args.cli
    env["CLAUDE_PROJECT_DIR"] = str(e2e)

    def run(payload_path: Path) -> tuple[int, str, str]:
        proc = subprocess.run(
            ["bash", str(script)],
            input=payload_path.read_text(encoding="utf-8"),
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        return proc.returncode, proc.stdout, proc.stderr

    problems = []

    # 1. The forbidden call is denied, with the gate's own sentence as the
    #    reason the model reads. A deny must not look like a pass: exit 0 with
    #    a `permissionDecision: deny` payload is the shape Claude Code honours.
    code, out, err = run(e2e / "payload-deny.json")
    if code != 0:
        problems.append(f"the deny payload exited {code}, not 0: {err.strip()[:200]}")
    try:
        decision = json.loads(out)
        hook = decision.get("hookSpecificOutput", {})
        if hook.get("hookEventName") != "PreToolUse":
            problems.append(f"the event name is {hook.get('hookEventName')!r}")
        if hook.get("permissionDecision") != "deny":
            problems.append(
                f"the decision is {hook.get('permissionDecision')!r}, not 'deny'"
            )
        reason = hook.get("permissionDecisionReason", "")
        if "refused" not in reason.lower():
            problems.append(f"the deny reason does not say it refused: {reason[:120]!r}")
        if "Re-emit" not in reason:
            problems.append("the deny reason does not carry the retry prompt")
    except json.JSONDecodeError:
        problems.append(f"the deny payload is not JSON: {out[:200]!r}")

    # 2. The allowed call passes: no output, exit 0, so Claude Code keeps its
    #    normal permission flow.
    code, out, err = run(e2e / "payload-allow.json")
    if code != 0 or out.strip():
        problems.append(
            f"the allow payload was not a no-op: exit {code}, stdout {out[:120]!r}"
        )

    # 3. A tool with no declaration is not gated.
    undeclared = e2e / "payload-undeclared.json"
    undeclared.write_text(
        json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_input": {"file_path": "anything"},
            }
        ),
        encoding="utf-8",
    )
    code, out, err = run(undeclared)
    if code != 0 or out.strip():
        problems.append(f"an undeclared tool was gated: exit {code}")
    undeclared.unlink()

    # 4. The recorded denial is the interesting one: the model never called the
    #    MCP gate tool. It went straight for the Bash tool -- the bypass the
    #    audit cares about -- and was still refused. A transcript where the
    #    model had called `interjson_gate` first would prove much less.
    tools = tools_used(e2e / "hook-deny.jsonl")
    if "Bash" not in tools:
        problems.append(f"the denied session did not call Bash: {tools}")
    if any(t.startswith("mcp__") for t in tools):
        problems.append(
            f"the denied session called an MCP tool ({tools}); "
            "the point is that the model bypassed MCP and was still refused"
        )
    allowed_tools = tools_used(e2e / "hook-allow.jsonl")
    if allowed_tools != ["Bash"]:
        problems.append(f"the allowed session is not a plain Bash call: {allowed_tools}")

    # 5. A *broken* gate must block, and blocking means exit 2: Claude Code
    #    treats exit 1 as "the hook errored" and runs the tool anyway. This was
    #    found by the real session and is why the recipe now exits 2.
    broken = dict(env)
    broken["INTERJSON_BIN"] = "/nonexistent/interjson"
    proc = subprocess.run(
        ["bash", str(script)],
        input=(e2e / "payload-allow.json").read_text(encoding="utf-8"),
        capture_output=True,
        text=True,
        env=broken,
        timeout=60,
    )
    if proc.returncode != 2:
        problems.append(
            f"a broken gate exited {proc.returncode}, not 2; Claude Code would run the tool"
        )
    if "refusing to run" not in proc.stderr:
        problems.append(f"a broken gate said nothing useful: {proc.stderr[:120]!r}")

    print("deny payload   -> denied, with the retry prompt")
    print("allow payload  -> allowed")
    print("undeclared     -> not gated")
    print("broken gate    -> exit 2 (blocks)")
    if problems:
        print("FAIL:")
        for p in problems:
            print("  " + p)
        return 1
    print("ok: the recorded PreToolUse wiring gates a real tool call")
    return 0


if __name__ == "__main__":
    sys.exit(main())
