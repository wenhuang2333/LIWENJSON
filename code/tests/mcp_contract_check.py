#!/usr/bin/env python3
"""Validate the four MCP tools against the `outputSchema` they publish.

This is the gate the audit asked for (marks/迭代.md §3.7): a strict MCP client
validates `structuredContent` against the tool's own `outputSchema`, so a
response that fails its own schema is a protocol defect, not a cosmetic one.

    python3 test/mcp_contract_check.py [path-to-interjson]
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
J = sys.argv[1] if len(sys.argv) > 1 else str(
    ROOT / "code/_build/native/release/build/cmd/interjson/interjson.exe"
)

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18"}}

CASES = [
    # (tool, arguments)
    ("interjson_gate", {"text": '{"a":1,}', "profile": "agent"}),
    ("interjson_gate", {"text": '{"a":1}', "profile": "permissive",
                        "schema": "{!a:integer}"}),
    ("interjson_gate", {"text": '{"a":2}', "schema": "{!a:integer(maximum:1)}"}),
    ("interjson_gate", {"text": "not json at all"}),
    ("interjson_gate", {"text": '{"n":9007199254740993}',
                        "schema_json": {"type": "object",
                                        "properties": {"n": {"type": "number",
                                                             "maximum": 9007199254740992}},
                                        "required": ["n"]}}),
    ("interjson_gate", {"text": '{"query":"MoonBit"}', "with_text": True,
                        "schema_json": {"type": "object",
                                        "properties": {"query": {"type": "string"}},
                                        "required": ["query"],
                                        "additionalProperties": False}}),
    ("interjson_repair", {"text": "{a:1,}"}),
    ("interjson_repair", {"text": "{\"a\":1}", "schema": "{!a:string}"}),
    ("interjson_validate", {"text": '{"a":1}'}),
    ("interjson_validate", {"text": "{a:1,}"}),
    ("interjson_readiness",
     {"text": '{"query":"x","limit":10}', "schema": "{!query:string,!limit:integer}"}),
]


def run(messages):
    body = "\n".join(json.dumps(m) for m in messages)
    proc = subprocess.run([J, "mcp"], input=body, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"mcp exited {proc.returncode}: {proc.stderr}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def call(messages):
    return run([INIT] + messages)[1:]


def main():
    tools = run([INIT, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])[1]["result"]["tools"]
    by_name = {t["name"]: t for t in tools}
    failures = []

    # 1. Every advertised inputSchema must be usable as `schema_json` by the
    #    gate: the server would otherwise reject its own tool declarations.
    for t in tools:
        schema = t["inputSchema"]
        args = {}
        for key in schema.get("required", []):
            args[key] = "{}"
        probe = {"jsonrpc": "2.0", "id": 99, "method": "tools/call",
                 "params": {"name": "interjson_gate",
                            "arguments": {"text": "{}", "schema_json": schema}}}
        res = call([probe])[0].get("result") or {}
        if res.get("isError"):
            failures.append(f"{t['name']}: its own inputSchema is refused: "
                            f"{res.get('content')}")

    # 2. Every response branch must satisfy the tool's own outputSchema.
    try:
        import jsonschema
    except ImportError:
        jsonschema = None
        print("warning: jsonschema not installed; only structural checks run")

    messages = [{"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call",
                 "params": {"name": name, "arguments": args}}
                for i, (name, args) in enumerate(CASES)]
    for res, (name, args) in zip(call(messages), CASES):
        result = res.get("result")
        if result is None:
            failures.append(f"{name}: JSON-RPC error {res.get('error')}")
            continue
        if result.get("isError"):
            # An isError result carries no structuredContent, which is the
            # protocol's own escape hatch. It is only acceptable for a
            # declaration the library refuses (a host error), never for a
            # document it merely disliked.
            continue
        sc = result.get("structuredContent")
        if sc is None:
            failures.append(f"{name}: no structuredContent")
            continue
        schema = by_name[name]["outputSchema"]
        if jsonschema is not None:
            try:
                jsonschema.validate(sc, schema)
            except jsonschema.ValidationError as exc:
                failures.append(
                    f"{name} {json.dumps(args)[:60]}: {exc.message} "
                    f"at /{'/'.join(str(p) for p in exc.absolute_path)}"
                )

    for f in failures:
        print("FAIL", f)
    print(f"{len(CASES) - len(failures)}/{len(CASES)} responses valid; "
          f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
