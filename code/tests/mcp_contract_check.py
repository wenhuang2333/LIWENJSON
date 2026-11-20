#!/usr/bin/env python3
"""Validate the four MCP tools against the schemas they publish.

This is the gate the audit asked for (marks/迭代.md §3.7): a strict MCP client
validates `structuredContent` against the tool's own `outputSchema`, so a
response that fails its own schema is a protocol defect, not a cosmetic one.

R-08 (marks/1120测试.md §8) widened it from "responses validate" to "the whole
published contract is exercised":

  1. the gate's `inputSchema` accepts the real arguments, including
     `with_text` (a boolean the server has always understood but the published
     schema never declared, so a strict client validating its own request would
     have rejected it);
  2. the readiness `inputSchema` accepts `step` 0/1/100 and rejects 0.5, -1,
     strings and booleans (the server takes an integer `step`; a schema that
     says nothing is a schema that validates nothing);
  3. every case request is validated against the tool's `inputSchema` *before*
     it is sent, so a test that only knows the old arguments cannot keep passing
     against a changed contract;
  4. every response's `structuredContent` is validated against the tool's
     `outputSchema`;
  5. `--strict` makes a missing `jsonschema` a hard failure (exit 2): a gate
     that could not run must not print a pass count. The CI job installs the
     pinned validator itself, because a dependency installed in another job is
     not installed here.

    python3 code/tests/mcp_contract_check.py [path-to-liwenjson] [--strict]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18"}}

# Requests the tools are actually called with. Each one is validated against the
# tool's published `inputSchema` before the call, so these are a contract test,
# not only a smoke test.
CASES = [
    # (tool, arguments)
    ("liwenjson_gate", {"text": '{"a":1,}', "profile": "agent"}),
    ("liwenjson_gate", {"text": '{"a":1}', "profile": "permissive",
                        "schema": "{!a:integer}"}),
    ("liwenjson_gate", {"text": '{"a":2}', "schema": "{!a:integer(maximum:1)}"}),
    ("liwenjson_gate", {"text": "not json at all"}),
    ("liwenjson_gate", {"text": '{"n":9007199254740993}',
                        "schema_json": {"type": "object",
                                        "properties": {"n": {"type": "number",
                                                             "maximum": 9007199254740992}},
                                        "required": ["n"]}}),
    # R-08 (1): the real gate call. `with_text` is served by the server; the
    # published schema has to declare it or a strict client never sends it.
    ("liwenjson_gate", {"text": '{"query":"MoonBit"}', "with_text": True,
                        "schema_json": {"type": "object",
                                        "properties": {"query": {"type": "string"}},
                                        "required": ["query"],
                                        "additionalProperties": False}}),
    ("liwenjson_repair", {"text": "{a:1,}"}),
    ("liwenjson_repair", {"text": "{\"a\":1}", "schema": "{!a:string}"}),
    ("liwenjson_validate", {"text": '{"a":1}'}),
    ("liwenjson_validate", {"text": "{a:1,}"}),
    ("liwenjson_readiness",
     {"text": '{"query":"x","limit":10}', "schema": "{!query:string,!limit:integer}"}),
    # R-08 (2): the readiness granularity is a real argument.
    ("liwenjson_readiness",
     {"text": '{"a":1}', "schema": "{!a:integer}", "step": 0}),
    ("liwenjson_readiness",
     {"text": '{"a":1}', "schema": "{!a:integer}", "step": 100}),
]

# Contract probes that decide whether the published `inputSchema` describes the
# real argument space. An accepted probe must validate; a rejected probe must
# fail validation. These are checked against the schema itself, before any call.
CONTRACT = [
    # R-08 (1): the gate accepts `with_text`, and it is a boolean.
    ("liwenjson_gate", {"text": "{}", "with_text": True}, True,
     "gate must accept with_text=true (a real argument)"),
    ("liwenjson_gate", {"text": "{}", "with_text": False}, True,
     "gate must accept with_text=false"),
    ("liwenjson_gate", {"text": "{}", "with_text": "yes"}, False,
     "gate must reject a non-boolean with_text"),
    # R-08 (2): integer step, in range, no coercion from strings/floats.
    ("liwenjson_readiness", {"text": "{}", "step": 0}, True,
     "readiness must accept step=0"),
    ("liwenjson_readiness", {"text": "{}", "step": 1}, True,
     "readiness must accept step=1"),
    ("liwenjson_readiness", {"text": "{}", "step": 100}, True,
     "readiness must accept step=100"),
    ("liwenjson_readiness", {"text": "{}", "step": 0.5}, False,
     "readiness must reject a fractional step"),
    ("liwenjson_readiness", {"text": "{}", "step": "1"}, False,
     "readiness must reject a string step"),
    ("liwenjson_readiness", {"text": "{}", "step": True}, False,
     "readiness must reject a boolean step"),
    ("liwenjson_readiness", {"text": "{}", "step": -1}, False,
     "readiness must reject a negative step"),
    # The required member is still required.
    ("liwenjson_gate", {"with_text": True}, False,
     "gate must reject arguments without text"),
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
    parser = argparse.ArgumentParser()
    parser.add_argument("cli", nargs="?", default=str(
        ROOT / "code/_build/native/release/build/cmd/liwenjson/liwenjson.exe"))
    parser.add_argument(
        "--strict", action="store_true",
        help="exit 2 when jsonschema is missing instead of skipping the schema "
        "checks; use this everywhere the result is quoted as a pass")
    args = parser.parse_args()

    global J
    J = args.cli

    # `tools/list` is structural: never needs jsonschema.
    tools = run([INIT, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])[1]["result"]["tools"]
    by_name = {t["name"]: t for t in tools}
    failures = []

    # 1. Every advertised inputSchema must be usable as `schema_json` by the
    #    gate: the server would otherwise reject its own tool declarations.
    for t in tools:
        schema = t["inputSchema"]
        probe = {"jsonrpc": "2.0", "id": 99, "method": "tools/call",
                 "params": {"name": "liwenjson_gate",
                            "arguments": {"text": "{}", "schema_json": schema}}}
        res = call([probe])[0].get("result") or {}
        if res.get("isError"):
            failures.append(f"{t['name']}: its own inputSchema is refused: "
                            f"{res.get('content')}")

    # 2. The response side needs a real validator. Without one this is a
    #    structural smoke test, and it must not be quoted as a schema pass.
    try:
        import jsonschema
    except ImportError:
        jsonschema = None
        if args.strict:
            print(
                "jsonschema is not installed; the strict MCP contract check "
                "cannot validate inputSchema/outputSchema. Install it "
                "(pip install jsonschema==4.26.0) and run again.",
                file=sys.stderr,
            )
            return 2
        print("warning: jsonschema not installed; only structural checks run "
              "(pass --strict to make this a failure)")

    if jsonschema is not None:
        for t in tools:
            for kind in ("inputSchema", "outputSchema"):
                schema = t.get(kind)
                if schema is None:
                    failures.append(f"{t['name']}: no {kind}")
                    continue
                try:
                    jsonschema.Draft202012Validator.check_schema(schema)
                except jsonschema.SchemaError as exc:
                    failures.append(
                        f"{t['name']}: published {kind} is not a valid JSON "
                        f"Schema: {exc.message}")

        # 3. The published argument space: accepted probes must validate,
        #    rejected probes must not. This is what catches a schema that was
        #    never updated when an argument was added (`with_text`, `step`).
        for name, probe_args, want_valid, why in CONTRACT:
            schema = by_name.get(name, {}).get("inputSchema")
            if schema is None:
                failures.append(f"{name}: no inputSchema to check: {why}")
                continue
            valid = jsonschema.Draft202012Validator(schema).is_valid(probe_args)
            if valid != want_valid:
                verb = "accept" if want_valid else "reject"
                failures.append(
                    f"{name}: inputSchema must {verb} {json.dumps(probe_args, ensure_ascii=False)} "
                    f"({why}); it does not")

    # 4. Every case request is validated against the tool's inputSchema
    #    *before* the call, then every response against its outputSchema.
    messages = [{"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call",
                 "params": {"name": name, "arguments": args}}
                for i, (name, args) in enumerate(CASES)]

    case_failures = 0
    for (name, args), message in zip(CASES, messages):
        schema = by_name.get(name, {}).get("inputSchema")
        if schema is not None and jsonschema is not None:
            try:
                jsonschema.validate(args, schema)
            except jsonschema.ValidationError as exc:
                case_failures += 1
                failures.append(
                    f"{name}: the case request is not valid against the "
                    f"published inputSchema: {exc.message} "
                    f"at /{'/'.join(str(p) for p in exc.absolute_path)}")
                message = None
        elif schema is None:
            case_failures += 1
            failures.append(f"{name}: tool not advertised by tools/list")
            message = None

    responses = call([m for m in messages if m is not None]) if any(
        m is not None for m in messages) else []
    sent = [m for m in messages if m is not None]
    for res, message in zip(responses, sent):
        name = message["params"]["name"]
        result = res.get("result")
        if result is None:
            case_failures += 1
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
            case_failures += 1
            failures.append(f"{name}: no structuredContent")
            continue
        schema = by_name[name]["outputSchema"]
        if jsonschema is not None:
            try:
                jsonschema.validate(sc, schema)
            except jsonschema.ValidationError as exc:
                case_failures += 1
                failures.append(
                    f"{name} {json.dumps(message['params']['arguments'])[:60]}: "
                    f"{exc.message} at "
                    f"/{'/'.join(str(p) for p in exc.absolute_path)}")

    for f in failures:
        print("FAIL", f)
    print()
    print(f"{len(CASES) - case_failures}/{len(CASES)} responses valid; "
          f"{len(failures)} failure(s)")
    if failures:
        print("mcp_contract_check: FAILED — the published contract and the "
              "server disagree; see the FAIL lines above.")
        return 1
    print("mcp_contract_check: OK — every request matches the published "
          "inputSchema and every response matches its outputSchema")
    return 0


if __name__ == "__main__":
    sys.exit(main())
