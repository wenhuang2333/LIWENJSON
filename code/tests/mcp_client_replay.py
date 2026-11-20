#!/usr/bin/env python3
"""Replay a real MCP client's handshake against this server.

The audit asked for at least one mandatory host integration verified against a
real client session (marks/迭代.md §8.3). A full session needs a logged-in
model, which CI does not have; the *handshake* does not, and it is the part
that breaks silently -- a client that gets the wrong envelope, the wrong
revision or an error where it expected an answer simply does not connect.

The recorded file is what Claude Code 2.1.308 sent on connect, verbatim:

    server/discover           (a probe, before the handshake)
    initialize                (with the revision it wants)
    notifications/initialized
    tools/list

This replays it and checks three things: every request is answered, the
handshake negotiates a revision the server implements, and the tool list the
client receives is the one the server publishes.

    python3 code/tests/mcp_client_replay.py [--cli path-to-liwenjson]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE = ROOT / "code" / "llm" / "fixtures" / "real_client_handshake.jsonl"
DEFAULT_CLI = ROOT / "code/_build/native/release/build/cmd/liwenjson/liwenjson.exe"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=os.environ.get("LIWENJSON_BIN", str(DEFAULT_CLI)))
    ap.add_argument("--fixture", default=str(FIXTURE))
    args = ap.parse_args()

    if not os.path.exists(args.cli):
        print(f"no binary at {args.cli}", file=sys.stderr)
        return 2
    if not os.path.exists(args.fixture):
        print(f"no recorded handshake at {args.fixture}", file=sys.stderr)
        return 2

    requests = [
        json.loads(line)
        for line in open(args.fixture, encoding="utf-8")
        if line.strip()
    ]
    body = "\n".join(json.dumps(r) for r in requests) + "\n"

    import subprocess

    proc = subprocess.run(
        [args.cli, "mcp"], input=body, capture_output=True, text=True, timeout=120
    )
    if proc.returncode != 0:
        print(f"the server exited {proc.returncode}: {proc.stderr.strip()[:300]}", file=sys.stderr)
        return 1
    responses = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
    by_id = {r.get("id"): r for r in responses if r.get("id") is not None}

    problems = []
    for req in requests:
        rid = req.get("id")
        if rid is None:
            # A notification is never answered, by the protocol.
            continue
        if rid not in by_id:
            problems.append(f"no answer to {req.get('method')} (id={rid!r})")
            continue
        answer = by_id[rid]
        if "error" in answer:
            problems.append(
                f"{req.get('method')} was refused: {answer['error'].get('message')}"
            )

    init = by_id.get(0) or {}
    negotiated = ((init.get("result") or {}).get("protocolVersion")) or ""
    if negotiated not in ("2025-06-18", "2025-03-26", "2024-11-05"):
        problems.append(f"the handshake negotiated an unknown revision {negotiated!r}")

    tools_answer = by_id.get(1) or {}
    tools = ((tools_answer.get("result") or {}).get("tools")) or []
    names = [t.get("name") for t in tools]
    for want in (
        "liwenjson_gate",
        "liwenjson_repair",
        "liwenjson_validate",
        "liwenjson_readiness",
    ):
        if want not in names:
            problems.append(f"the tool list is missing {want}")

    print("client requests:", ", ".join(r.get("method", "?") for r in requests))
    print("negotiated revision:", negotiated)
    print("tools:", ", ".join(n for n in names if n))
    if problems:
        print("FAIL:")
        for p in problems:
            print("  " + p)
        return 1
    print("ok: a real client's handshake is answered, and the tools arrive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
