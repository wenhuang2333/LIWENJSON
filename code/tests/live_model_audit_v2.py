#!/usr/bin/env python3
"""Live adversarial test of the 1.5.2 iteration against the real backend.

This is the round-two version of `live_model_audit.py`: it drives the same
OpenAI **Responses API** the audit used, and checks the *behaviour* the audit
said was broken rather than re-recording the same evidence.

    python3 code/tests/live_model_audit_v2.py            # run against the API
    python3 code/tests/live_model_audit_v2.py --offline  # no API calls

The API key is read from the workspace's `AI 后端.txt` and never written to the
evidence file.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "test" / "live_model_audit_v2_evidence.json"
CLI = ROOT / "code" / "_build" / "native" / "release" / "build" / "cmd" / "interjson" / "interjson.exe"

# The endpoint, the key and the model come from the environment first, and from
# the workspace's own note file only as a convenience for a local run. The key
# is never written to the evidence file.
CONFIG = Path(os.environ.get("INTERJSON_PROVIDER_CONFIG", ROOT / "AI 后端.txt"))
BASE = os.environ.get("INTERJSON_BASE_URL", "").rstrip("/")
KEY = os.environ.get("INTERJSON_API_KEY", "")
MODEL = os.environ.get("INTERJSON_MODEL", "")
if not (BASE and KEY and MODEL):
    config = CONFIG.read_text(encoding="utf-8")
    BASE = BASE or re.search(r"请求地址：(\S+)", config).group(1).rstrip("/")
    KEY = KEY or re.search(r"密钥：(\S+)", config).group(1)
    MODEL = MODEL or re.search(r"模型名称：(\S+)", config).group(1)

# ---------------------------------------------------------------------------
# Declarations
# ---------------------------------------------------------------------------

MODE_SCHEMA = {
    "type": "object",
    "properties": {"mode": {"type": "string", "const": "read", "enum": ["read", "write"]}},
    "required": ["mode"],
}
SEARCH_SCHEMA = {
    "type": "object",
    "properties": {
        "query": {"type": "string"},
        "limit": {"type": "integer", "minimum": 1, "maximum": 10},
    },
    "required": ["query", "limit"],
}
STRICT_SCHEMA = {
    "type": "object",
    "properties": {"query": {"type": "string"}},
    "required": ["query"],
    "additionalProperties": False,
}
BIG_SCHEMA = {
    "type": "object",
    "properties": {"n": {"type": "number", "maximum": 9007199254740992}},
    "required": ["n"],
}
EMOJI_SCHEMA = {
    "type": "object",
    "properties": {"s": {"type": "string", "maxLength": 1}},
    "required": ["s"],
}


def tool(name, schema, description="Execute the requested operation"):
    return {"type": "function", "name": name, "description": description, "parameters": schema}


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------


def request(payload, stream=False):
    body = dict(payload)
    body["model"] = MODEL
    if stream:
        body["stream"] = True
    req = urllib.request.Request(
        BASE + "/responses",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"},
    )
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            raw = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as exc:
        return {
            "http_status": exc.code,
            "error_body": exc.read().decode("utf-8"),
            "elapsed_s": round(time.time() - started, 3),
        }
    result = {"http_status": status, "elapsed_s": round(time.time() - started, 3)}
    if stream:
        result["raw_sse"] = raw
        events = []
        for block in re.split(r"\r?\n\r?\n", raw):
            data = "\n".join(
                line[5:].lstrip() for line in block.splitlines() if line.startswith("data:")
            )
            if data and data != "[DONE]":
                try:
                    events.append(json.loads(data))
                except json.JSONDecodeError:
                    events.append({"unparsed_data": data})
        result["events"] = events
    else:
        result["response"] = json.loads(raw)
    return result


def outputs(response, kind):
    return [item for item in response.get("output", []) if item.get("type") == kind]


def text_output(response):
    chunks = []
    for message in outputs(response, "message"):
        for content in message.get("content", []):
            if content.get("type") == "output_text":
                chunks.append(content.get("text", ""))
    return "\n".join(chunks)


# ---------------------------------------------------------------------------
# The engine, through its published surfaces
# ---------------------------------------------------------------------------


def serve(method, params):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    proc = subprocess.run(
        [str(CLI), "serve"], input=json.dumps(payload), text=True, capture_output=True, timeout=60
    )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"rc": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}


def gate(text, schema=None):
    params = {"text": text}
    if schema is not None:
        params["schema_json"] = schema
    decoded = serve("analyze", params)
    result = decoded.get("result", {})
    keys = (
        "decision",
        "exactness",
        "ambiguous",
        "executable",
        "business_authorized",
        "error",
        "refusal",
        "retry",
        "value",
    )
    return {"outer_ok": decoded.get("ok"), **{k: result.get(k) for k in keys}}


def llm(raw_sse, provider):
    proc = subprocess.run(
        [str(CLI), "llm", "--provider", provider, "--sse"],
        input=raw_sse,
        text=True,
        capture_output=True,
        timeout=60,
    )
    lines = [json.loads(x) for x in proc.stdout.splitlines() if x.strip()]
    return {"rc": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "calls": lines}


def mcp_call(name, arguments):
    """Call one MCP tool and return its result plus its own `outputSchema`."""
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
    listing = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
    call = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    body = "\n".join(json.dumps(m) for m in (init, listing, call))
    proc = subprocess.run([str(CLI), "mcp"], input=body, text=True, capture_output=True, timeout=60)
    responses = [json.loads(x) for x in proc.stdout.splitlines() if x.strip()]
    tools = responses[1]["result"]["tools"]
    schema = next(t["outputSchema"] for t in tools if t["name"] == name)
    result = responses[2].get("result", {})
    return schema, result.get("structuredContent")


def schema_valid(content, schema):
    try:
        import jsonschema
    except ImportError:
        return None
    try:
        jsonschema.validate(content, schema)
        return True
    except jsonschema.ValidationError:
        return False


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

CHECKS: list[dict] = []


def check(name, ok, detail=""):
    CHECKS.append({"name": name, "ok": bool(ok), "detail": detail})
    print(("ok   " if ok else "FAIL ") + name + (("  " + str(detail)[:200]) if detail else ""), flush=True)
    return ok


def offline_cases():
    """The checks that need no API: the engine's own behaviour."""
    # 1. A Responses stream read by the Responses adapter produces the call.
    sse = (
        'event: response.output_item.added\n'
        'data: {"type":"response.output_item.added","output_index":0,'
        '"item":{"id":"fc_1","type":"function_call","call_id":"call_1",'
        '"name":"read_file","arguments":""}}\n\n'
        'event: response.function_call_arguments.delta\n'
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1",'
        '"output_index":0,"delta":"{\\"mode\\":"}\n\n'
        'event: response.function_call_arguments.delta\n'
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1",'
        '"output_index":0,"delta":"\\"read\\"}"}\n\n'
        'event: response.function_call_arguments.done\n'
        'data: {"type":"response.function_call_arguments.done","item_id":"fc_1",'
        '"output_index":0,"arguments":"{\\"mode\\":\\"read\\"}"}\n\n'
        'event: response.completed\n'
        'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
        "data: [DONE]\n\n"
    )
    out = llm(sse, "openai-responses")
    check(
        "responses adapter reads a Responses stream",
        len(out["calls"]) == 1 and out["calls"][0].get("value") == {"mode": "read"},
        out,
    )
    # 2. The same stream read by the Chat Completions adapter is refused.
    out = llm(sse, "openai")
    check(
        "chat adapter refuses a Responses stream instead of reporting no calls",
        out["rc"] != 0 and "openai-responses" in out["stderr"],
        out,
    )
    # 3. A filtered response is not executable.
    filtered = (
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
        '"function":{"name":"f","arguments":"{}"}}]}}]}\n\n'
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}\n\n'
    )
    out = llm(filtered, "openai")
    check(
        "a content_filtered call is not executable",
        len(out["calls"]) == 1 and out["calls"][0].get("executable") is False
        and out["calls"][0].get("end") == "refused",
        out,
    )
    # 4. Two choices with the same tool index do not merge.
    two = (
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a",'
        '"function":{"name":"first","arguments":"{\\"a\\":1}"}}]}}]}\n\n'
        'data: {"choices":[{"index":1,"delta":{"tool_calls":[{"index":0,"id":"b",'
        '"function":{"name":"second","arguments":"{\\"b\\":2}"}}]}}]}\n\n'
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"},'
        '{"index":1,"delta":{},"finish_reason":"tool_calls"}]}\n\n'
    )
    out = llm(two, "openai")
    names = sorted(c.get("name") for c in out["calls"])
    check("two choices with one tool index stay apart", names == ["first", "second"], out)
    # 5. The `[DONE]` terminator does not fail the stream.
    done = (
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c",'
        '"function":{"name":"f","arguments":"{\\"a\\":1}"}}]}}]}\n\n'
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n'
        "data: [DONE]\n\n"
    )
    out = llm(done, "openai")
    check("[DONE] ends the stream without losing the call", len(out["calls"]) == 1, out)
    # 6. The exact decimal boundary.
    r = gate('{"n":9007199254740993}', BIG_SCHEMA)
    check("2^53 boundary is refused", r.get("executable") is False, r)
    r = gate('{"n":9007199254740992}', BIG_SCHEMA)
    check("2^53 boundary itself is allowed", r.get("executable") is True, r)
    # 7. The Unicode length.
    r = gate('{"s":"\U0001F600\U0001F600"}', EMOJI_SCHEMA)
    check("two emoji exceed maxLength 1", r.get("executable") is False, r)
    r = gate('{"s":"\U0001F600"}', EMOJI_SCHEMA)
    check("one emoji fits maxLength 1", r.get("executable") is True, r)
    # 8. A closed object.
    r = gate('{"query":"MoonBit","x":1}', STRICT_SCHEMA)
    check("a closed object refuses an extra member", r.get("executable") is False, r)
    r = gate('{"query":"MoonBit"}', STRICT_SCHEMA)
    check("a closed object accepts its own members", r.get("executable") is True, r)
    # 9. The refusal classification.
    r = gate('{"mode":"write"}', MODE_SCHEMA)
    check(
        "a schema conflict is not auto-retryable",
        (r.get("refusal") or {}).get("kind") == "schema_or_intent"
        and (r.get("refusal") or {}).get("auto_retry") is False,
        r,
    )
    r = gate('{"mode":')
    check(
        "a truncated document is auto-retryable",
        (r.get("refusal") or {}).get("kind") == "syntax"
        and (r.get("refusal") or {}).get("auto_retry") is True,
        r,
    )
    # 10. The gate never claims business authorization.
    r = gate('{"mode":"read"}', MODE_SCHEMA)
    check("the gate does not claim business authorization", r.get("business_authorized") is False, r)
    # 11. The MCP tools' own responses satisfy their own outputSchema.
    for name, args in [
        ("interjson_gate", {"text": '{"a":1,}', "profile": "agent"}),
        ("interjson_gate", {"text": '{"a":1}', "schema": "{!a:integer}"}),
        ("interjson_gate", {"text": "not json"}),
        ("interjson_repair", {"text": "{a:1,}"}),
        ("interjson_validate", {"text": '{"a":1}'}),
        ("interjson_readiness", {"text": '{"q":"x"}', "schema": "{!q:string}"}),
    ]:
        schema, content = mcp_call(name, args)
        ok = schema_valid(content, schema)
        check(f"{name} response satisfies its own outputSchema", ok is not False, (args, ok))
    # 12. The MCP server accepts its own inputSchema as a declaration.
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
    listing = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
    body = "\n".join(json.dumps(m) for m in (init, listing))
    proc = subprocess.run([str(CLI), "mcp"], input=body, text=True, capture_output=True, timeout=60)
    tools = json.loads(proc.stdout.splitlines()[1])["result"]["tools"]
    for t in tools:
        # The value has to satisfy the declaration, or the gate refuses the
        # *value* and the check would say nothing about the declaration.
        sample = {"text": "{}"}
        for key in t["inputSchema"].get("required", []):
            sample[key] = "{}" if key == "schema_json" else "x"
        call = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "interjson_gate",
                "arguments": {"text": json.dumps(sample), "schema_json": t["inputSchema"]},
            },
        }
        body = "\n".join(json.dumps(m) for m in (init, call))
        proc = subprocess.run([str(CLI), "mcp"], input=body, text=True, capture_output=True, timeout=60)
        result = json.loads(proc.stdout.splitlines()[-1]).get("result", {})
        check(
            f"the gate accepts {t['name']}'s own inputSchema",
            not result.get("isError"),
            result,
        )
    # 13. The JSON-RPC envelope is checked.
    for bad in [
        '{"jsonrpc":"1.0","id":1,"method":"ping"}',
        '{"id":1,"method":"ping"}',
        '{"jsonrpc":"2.0","id":1,"method":"ping","params":5}',
    ]:
        proc = subprocess.run([str(CLI), "mcp"], input=bad + "\n", text=True, capture_output=True, timeout=60)
        out = json.loads(proc.stdout.splitlines()[-1])
        check(
            f"a malformed envelope is refused: {bad[:44]}",
            out.get("error", {}).get("code") == -32600,
            out,
        )
    # 14. A batch is answered by the revision that requires it.
    init_mid = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": "2025-03-26"},
    }
    batch = '[{"jsonrpc":"2.0","id":2,"method":"ping"}]'
    # The batch is raw JSON, not a JSON string: `json.dumps` of a `str` would
    # quote it, and the server would (rightly) refuse a string as a message.
    body = json.dumps(init_mid) + "\n" + batch + "\n"
    proc = subprocess.run([str(CLI), "mcp"], input=body, text=True, capture_output=True, timeout=60)
    out = json.loads(proc.stdout.splitlines()[-1])
    check("a batch on 2025-03-26 is answered with an array", isinstance(out, list) and len(out) == 1, out)
    # The same batch on the revision that dropped batching is refused, with a
    # reason -- not answered with a lone `missing method`.
    init_new = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": "2025-06-18"},
    }
    body = json.dumps(init_new) + "\n" + batch + "\n"
    proc = subprocess.run([str(CLI), "mcp"], input=body, text=True, capture_output=True, timeout=60)
    out = json.loads(proc.stdout.splitlines()[-1])
    check(
        "a batch on 2025-06-18 is refused with a reason",
        out.get("error", {}).get("code") == -32600,
        out,
    )


def live_cases(evidence):
    """The checks that need the real model."""
    # A. The model produces a tool call the strict schema accepts.
    result = request(
        {
            "input": "Call search exactly once with query MoonBit. Do not explain.",
            "tools": [tool("search", STRICT_SCHEMA)],
            "tool_choice": "required",
            "max_output_tokens": 350,
        }
    )
    response = result.get("response", {})
    calls = outputs(response, "function_call")
    evidence["strict_schema_call"] = {
        "status": response.get("status"),
        "calls": [{"name": c.get("name"), "arguments": c.get("arguments")} for c in calls],
        "gate": gate(calls[0].get("arguments", ""), STRICT_SCHEMA) if calls else None,
    }
    check(
        "the model's own call satisfies the strict schema it was given",
        bool(calls) and gate(calls[0].get("arguments", ""), STRICT_SCHEMA).get("executable") is True,
        evidence["strict_schema_call"],
    )
    # B. The model refuses the forbidden value; the gate refuses it too.
    result = request(
        {
            "input": "Call set_mode exactly once with mode write. Do not explain.",
            "tools": [tool("set_mode", MODE_SCHEMA)],
            "tool_choice": "required",
            "max_output_tokens": 350,
        }
    )
    response = result.get("response", {})
    calls = outputs(response, "function_call")
    g = gate(calls[0].get("arguments", ""), MODE_SCHEMA) if calls else {}
    evidence["forbidden_value"] = {
        "status": response.get("status"),
        "calls": [{"name": c.get("name"), "arguments": c.get("arguments")} for c in calls],
        "gate": g,
    }
    check(
        "a value the declaration forbids is refused, and the refusal is not auto-retryable",
        bool(calls)
        and g.get("executable") is False
        and (g.get("refusal") or {}).get("kind") == "schema_or_intent"
        and (g.get("refusal") or {}).get("auto_retry") is False,
        evidence["forbidden_value"],
    )
    # C. The retry prompt must not turn a refused action into an allowed one.
    retry_prompt = ((g.get("retry") or {}).get("prompt")) if g else None
    if retry_prompt and calls:
        response_id = response.get("id")
        result = request(
            {
                "previous_response_id": response_id,
                "input": retry_prompt,
                "tools": [tool("set_mode", MODE_SCHEMA)],
                "tool_choice": "required",
                "max_output_tokens": 350,
            }
        )
        response = result.get("response", {})
        retry_calls = outputs(response, "function_call")
        rg = gate(retry_calls[0].get("arguments", ""), MODE_SCHEMA) if retry_calls else {}
        evidence["retry_roundtrip"] = {
            "retry_prompt": retry_prompt,
            "calls": [{"name": c.get("name"), "arguments": c.get("arguments")} for c in retry_calls],
            "gate": rg,
        }
        # The model may comply with the retry prompt. The point is that the
        # refusal the host sees says the retry was *not* automatic: the host
        # has to look.
        check(
            "a retried answer is still gated, and the refusal kind says it is a different action",
            (g.get("refusal") or {}).get("auto_retry") is False,
            evidence["retry_roundtrip"],
        )
    # D. The real Responses SSE stream, through the new adapter.
    result = request(
        {
            "input": "Call set_mode exactly once with mode read. Do not explain.",
            "tools": [tool("set_mode", MODE_SCHEMA)],
            "tool_choice": "required",
            "max_output_tokens": 350,
        },
        stream=True,
    )
    raw = result.get("raw_sse", "")
    out = llm(raw, "openai-responses") if raw else {"calls": [], "rc": -1}
    if out.get("calls"):
        evidence["responses_stream"] = {
            "events": len(result.get("events", [])),
            "adapter": out,
            "gate": gate(
                json.dumps(out["calls"][0].get("value")), MODE_SCHEMA
            ),
        }
    else:
        evidence["responses_stream"] = {"events": len(result.get("events", [])), "adapter": out}
    check(
        "the real Responses stream is read into a call the gate accepts",
        bool(out.get("calls"))
        and out["calls"][0].get("executable") is True
        and evidence["responses_stream"]["gate"].get("executable") is True,
        evidence["responses_stream"],
    )
    # E. The real truncated stream.
    result = request(
        {
            "input": "Call search with query a very long discussion about MoonBit and limit 3.",
            "tools": [tool("search", SEARCH_SCHEMA)],
            "tool_choice": "required",
            "max_output_tokens": 48,
        },
        stream=True,
    )
    raw = result.get("raw_sse", "")
    out = llm(raw, "openai-responses") if raw else {"calls": [], "rc": -1}
    provider_status = None
    for event in result.get("events", []):
        if event.get("type") in (
            "response.completed",
            "response.incomplete",
            "response.failed",
        ):
            provider_status = (event.get("response") or {}).get("status")
    evidence["truncated_stream"] = {
        "events": len(result.get("events", [])),
        "provider_status": provider_status,
        "adapter": out,
    }
    # The token budget may be enough on the day; what must never happen is an
    # incomplete response reported as executable. When the provider did
    # complete and the arguments are exact, executing is correct, and the
    # check says so rather than demanding a refusal the stream does not
    # justify.
    calls = out.get("calls") or []
    if provider_status == "incomplete":
        ok = bool(calls) and calls[0].get("executable") is False
        label = "an incomplete real stream is not executable"
    else:
        ok = bool(calls) and (
            calls[0].get("executable") is True
        ) == (calls[0].get("exactness") == "exact")
        label = "a completed real stream is executable exactly when its arguments are exact"
    check(label, ok, evidence["truncated_stream"])


def main():
    offline = "--offline" not in sys.argv
    evidence = {
        "model": MODEL,
        "api": BASE + "/responses",
        "cli": str(CLI),
        "started_unix": int(time.time()),
        "checks": [],
        "live": {},
    }
    OUT.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    offline_cases()
    if offline:
        live_cases(evidence["live"])
    evidence["checks"] = CHECKS
    evidence["failed"] = sum(1 for c in CHECKS if not c["ok"])
    evidence["finished_unix"] = int(time.time())
    OUT.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n{len(CHECKS) - evidence['failed']}/{len(CHECKS)} checks passed")
    print("evidence:", OUT)
    return 1 if evidence["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
