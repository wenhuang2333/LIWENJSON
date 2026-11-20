#!/usr/bin/env python3
"""Serve/MCP protocol-contract conformance group.

Covers the parts of the protocol the tool declarations publish but that the
older corpus did not assert:

- a long-lived mode (`serve`, `mcp`) refuses the one-shot `--check` flag with a
  usage error (exit 2) instead of silently accepting it;
- `serve` frames are strict UTF-8: a malformed frame is a controlled `E040`
  (MCP: JSON-RPC `-32700`) and the connection keeps serving; a legal U+FFFD in
  a string is not a malformed frame;
- `watch.finish` on an empty stream re-raises the original `E001` error object
  and clears the stream, so the next `watch.start` works;
- a present-but-not-an-object `params` is a protocol error, not "no arguments";
- the `gate` inputSchema publishes `with_text` (boolean) and the `readiness`
  inputSchema publishes `step` (integer, 0..8388608), and the server refuses
  what the declaration rejects: fractions, wrong types, out-of-range values and
  undeclared fields, before the walk starts.

The script only talks stdio to a built binary; it needs no third-party module.

Usage:
    python3 code/tests/conformance/run_protocol_contract.py [--cli PATH]

Exit status is 0 when every check passes, 1 otherwise.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BIN = (
    ROOT
    / "code"
    / "_build"
    / "native"
    / "release"
    / "build"
    / "cmd"
    / "liwenjson"
    / "liwenjson.exe"
)

RESULTS: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str) -> None:
    RESULTS.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}", flush=True)


def run(binary: str, args: list[str], payload: bytes, timeout: int = 60) -> tuple[int, bytes, bytes]:
    proc = subprocess.run(
        [binary, *args],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr


def jsonl(rows: list[dict]) -> bytes:
    return b"".join(json.dumps(row, ensure_ascii=False).encode("utf-8") + b"\n" for row in rows)


def parse_lines(stdout: bytes) -> list[dict]:
    out: list[dict] = []
    for raw in stdout.split(b"\n"):
        if not raw.strip():
            continue
        out.append(json.loads(raw))
    return out


REPLACEMENT = b"\xef\xbf\xbd"


def serve(binary: str, payload: bytes) -> tuple[int, bytes, bytes, list[dict]]:
    rc, out, err = run(binary, ["serve"], payload)
    rows: list[dict] = []
    parse_error = None
    try:
        rows = parse_lines(out)
    except json.JSONDecodeError as exc:  # pragma: no cover - reported by caller
        parse_error = str(exc)
    if parse_error is not None:
        record("serve: every stdout line is JSON", False, parse_error)
    return rc, out, err, rows


def error_of(row: dict) -> dict:
    err = row.get("error")
    return err if isinstance(err, dict) else {}


def check_serve_flags(binary: str) -> None:
    for mode in ("serve", "mcp"):
        rc, out, err = run(binary, [mode, "--check"], b"")
        text = err.decode("utf-8", "replace")
        ok = rc == 2 and "--check" in text and mode in text and not out.strip()
        record(
            f"{mode}: --check is a usage error",
            ok,
            f"rc={rc} stderr={text.strip()[:120]!r}",
        )
    rc, out, err = run(binary, ["serve", "input.json"], b"")
    text = err.decode("utf-8", "replace")
    ok = rc == 2 and "file path" in text
    record("serve: a file path is a usage error", ok, f"rc={rc} stderr={text.strip()[:100]!r}")


def check_serve_utf8(binary: str) -> None:
    # A legal U+FFFD characters in a string is not a malformed frame.
    body = json.dumps({"id": 1, "method": "repair", "params": {"text": "{\"a\":\"\ufffd\"}"}}, ensure_ascii=False)
    rc, out, err, rows = serve(binary, body.encode("utf-8") + b"\n")
    ok = (
        rc == 0
        and len(rows) == 1
        and rows[0].get("ok") is True
        and rows[0]["result"].get("exactness") == "exact"
        and rows[0]["result"].get("text") == "{\"a\":\"\ufffd\"}"
    )
    record("serve: a legal U+FFFD string is accepted as exact", ok, f"rc={rc} rows={len(rows)}")

    # Raw 0xff inside a JSON string: not UTF-8, so the frame is refused with
    # E040, nothing is replacement-decoded, and the next request on the same
    # connection is answered.
    bad = (
        b'{"id":2,"method":"repair","params":{"text":"{\\"a\\":\\"'
        b"\xff"
        b'\\"}}"}\n'
    )
    good = json.dumps({"id": 3, "method": "hello"}).encode() + b"\n"
    rc, out, err, rows = serve(binary, bad + good)
    first = rows[0] if rows else {}
    err_obj = error_of(first)
    ok = (
        rc == 0
        and len(rows) == 2
        and first.get("ok") is False
        and err_obj.get("code") == "E040"
        and err_obj.get("exit") == 3
        and rows[1].get("ok") is True
        and rows[1]["result"].get("protocol") == 1
        and REPLACEMENT not in out
    )
    record(
        "serve: raw 0xff frame -> E040, no U+FFFD, connection continues",
        ok,
        f"rc={rc} rows={len(rows)} first_error={err_obj.get('code')} second_ok={rows[1].get('ok') if len(rows) > 1 else None}",
    )

    # Multi-byte characters are read byte by byte and must survive.
    text = "{\"emoji\":\"😀\",\"中文\":\"值\"}"
    body = json.dumps({"id": 4, "method": "repair", "params": {"text": text}}, ensure_ascii=False)
    rc, out, err, rows = serve(binary, body.encode("utf-8") + b"\n")
    ok = rc == 0 and len(rows) == 1 and rows[0].get("ok") is True and rows[0]["result"].get("text") == text
    record("serve: multi-byte UTF-8 frame survives", ok, f"rc={rc} rows={len(rows)}")


def check_serve_watch_finish(binary: str) -> None:
    payload = jsonl(
        [
            {"id": 1, "method": "watch.start", "params": {"text": ""}},
            {"id": 2, "method": "watch.finish", "params": {}},
            {"id": 3, "method": "watch.start", "params": {"text": ""}},
            {"id": 4, "method": "watch.finish", "params": {}},
        ]
    )
    rc, out, err, rows = serve(binary, payload)
    codes = [error_of(r).get("code") for r in rows]
    ok = (
        rc == 0
        and len(rows) == 4
        and rows[0].get("ok") is True
        and rows[1].get("ok") is False
        and codes[1] == "E001"
        and error_of(rows[1]).get("exit") == 3
        and "E030" not in json.dumps(rows[1])
        and rows[2].get("ok") is True
        and rows[3].get("ok") is False
        and codes[3] == "E001"
    )
    record(
        "serve: empty watch.finish keeps E001 and clears the stream",
        ok,
        f"rc={rc} codes={codes}",
    )


def check_serve_protocol_errors(binary: str) -> None:
    payload = (
        b'{"id":5,"method":"repair","params":5}\n'
        b'{"id":6,"method":"no.such.method"}\n'
        b"not json\n"
        b'{"id":7,"method":"hello"}\n'
    )
    rc, out, err, rows = serve(binary, payload)
    codes = [error_of(r).get("code") for r in rows]
    ok = (
        rc == 0
        and len(rows) == 4
        and codes[0] == "E050"
        and codes[1] == "E050"
        and codes[2] == "E060"
        and rows[3].get("ok") is True
    )
    record(
        "serve: bad params / unknown method / bad JSON are controlled, then serving continues",
        ok,
        f"codes={codes}",
    )


def mcp_session(binary: str, tail: list[dict], extra_raw: bytes = b"") -> tuple[int, bytes, list[dict]]:
    head = jsonl(
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "protocol-contract", "version": "0"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
    )
    payload = head + jsonl(tail) + extra_raw
    rc, out, err = run(binary, ["mcp"], payload)
    rows: list[dict] = []
    for raw in out.split(b"\n"):
        if not raw.strip():
            continue
        rows.append(json.loads(raw))
    # rows[0] is the initialize response; the notification produces nothing.
    return rc, out, rows


def tool_call(tool_id: int, name: str, arguments: dict) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": tool_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }


def check_mcp_schemas(binary: str) -> None:
    rc, out, rows = mcp_session(binary, [{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
    tools = {t["name"]: t for t in rows[1]["result"]["tools"]}
    gate = tools["liwenjson_gate"]["inputSchema"]
    ready = tools["liwenjson_readiness"]["inputSchema"]
    gate_props = gate["properties"]
    ready_props = ready["properties"]
    step = ready_props.get("step", {})
    ok = (
        rc == 0
        and gate_props.get("with_text", {}).get("type") == "boolean"
        and step.get("type") == "integer"
        and step.get("minimum") == 0
        and step.get("maximum") == 8388608
        and gate.get("additionalProperties") is False
        and ready.get("additionalProperties") is False
    )
    record(
        "mcp: gate publishes with_text, readiness publishes step 0..8388608",
        ok,
        f"with_text={gate_props.get('with_text')} step={step}",
    )


def check_mcp_arguments(binary: str) -> None:
    rc, out, rows = mcp_session(
        binary,
        [
            tool_call(2, "liwenjson_gate", {"text": '{"a":1}', "with_text": True}),
            tool_call(3, "liwenjson_gate", {"text": '{"a":1}'}),
            tool_call(4, "liwenjson_gate", {"text": '{"a":1}', "with_text": "yes"}),
            tool_call(5, "liwenjson_gate", {"text": '{"a":1}', "step": 1}),
            tool_call(6, "liwenjson_readiness", {"text": '{"a":1}', "step": 0}),
            tool_call(7, "liwenjson_readiness", {"text": '{"a":1}', "step": 1}),
            tool_call(8, "liwenjson_readiness", {"text": '{"a":1}', "step": 100}),
            tool_call(9, "liwenjson_readiness", {"text": '{"a":1}', "step": 8388608}),
            tool_call(10, "liwenjson_readiness", {"text": '{"a":1}', "step": 0.5}),
            tool_call(11, "liwenjson_readiness", {"text": '{"a":1}', "step": "1"}),
            tool_call(12, "liwenjson_readiness", {"text": '{"a":1}', "step": -1}),
            tool_call(13, "liwenjson_readiness", {"text": '{"a":1}', "step": 8388609}),
            tool_call(14, "liwenjson_readiness", {"text": '{"a":1}', "step": None}),
            tool_call(15, "liwenjson_readiness", {"text": '{"a":1}', "unknown_field": 1}),
        ],
    )

    def result(i: int) -> dict:
        return rows[i]["result"]

    def text(i: int) -> str:
        return result(i)["content"][0]["text"]

    def rejected(i: int) -> bool:
        return result(i).get("isError") is True and "E050" in text(i)

    assertions = {
        "2 gate with_text=true returns text": result(1).get("isError") is False
        and isinstance(result(1)["structuredContent"].get("text"), str),
        "3 gate default omits text": result(2).get("isError") is False
        and "text" not in result(2)["structuredContent"],
        "4 gate with_text=string refused": rejected(3),
        "5 gate does not accept step": rejected(4),
        "6 readiness step=0": result(5).get("isError") is False and result(5)["structuredContent"].get("step") == 0,
        "7 readiness step=1": result(6).get("isError") is False and result(6)["structuredContent"].get("step") == 1,
        "8 readiness step=100": result(7).get("isError") is False and result(7)["structuredContent"].get("step") == 100,
        "9 readiness step=8388608": result(8).get("isError") is False,
        "10 readiness step=0.5 refused": rejected(9),
        "11 readiness step=\"1\" refused": rejected(10),
        "12 readiness step=-1 refused": rejected(11),
        "13 readiness step=8388609 refused": rejected(12),
        "14 readiness step=null refused": rejected(13),
        "15 readiness unknown field refused": rejected(14),
    }
    failed = [name for name, ok in assertions.items() if not ok]
    record(
        "mcp: with_text and step are enforced before the walk",
        not failed,
        "all 14 argument checks passed" if not failed else "failed: " + "; ".join(failed),
    )


def check_mcp_frames(binary: str) -> None:
    # Invalid UTF-8 inside a well-formed JSON envelope: -32700, and a later
    # request on the same connection is still answered.
    head = jsonl(
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "protocol-contract", "version": "0"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
    )
    bad = b'{"jsonrpc":"2.0","id":2,"method":"ping","params":{"x":"\xff"}}\n'
    good = json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ping"}).encode() + b"\n"
    rc, out, err = run(binary, ["mcp"], head + bad + good)
    rows = [json.loads(raw) for raw in out.split(b"\n") if raw.strip()]
    ok = (
        rc == 0
        and len(rows) == 3
        and rows[1].get("error", {}).get("code") == -32700
        and REPLACEMENT not in out
        and rows[2].get("result") is not None
        and "error" not in rows[2]
    )
    record(
        "mcp: invalid UTF-8 frame -> -32700, connection continues, no U+FFFD",
        ok,
        f"rows={len(rows)} codes={[r.get('error', {}).get('code') for r in rows]}",
    )

    # A line that is not JSON, and a batch array on a revision without batching.
    rc, out, err = run(
        binary,
        ["mcp"],
        head + b"not json\n" + json.dumps({"jsonrpc": "2.0", "id": 4, "method": "ping"}).encode() + b"\n",
    )
    rows = [json.loads(raw) for raw in out.split(b"\n") if raw.strip()]
    ok = rc == 0 and len(rows) == 3 and rows[1].get("error", {}).get("code") == -32700 and "error" not in rows[2]
    record("mcp: invalid JSON line -> -32700, then serving continues", ok, f"rows={len(rows)}")


def main() -> int:
    binary = str(DEFAULT_BIN)
    args = sys.argv[1:]
    if args and args[0] == "--cli":
        binary = args[1]
    if not Path(binary).exists():
        print(f"binary not found: {binary}", file=sys.stderr)
        return 2
    check_serve_flags(binary)
    check_serve_utf8(binary)
    check_serve_watch_finish(binary)
    check_serve_protocol_errors(binary)
    check_mcp_schemas(binary)
    check_mcp_arguments(binary)
    check_mcp_frames(binary)
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    failed = len(RESULTS) - passed
    print(f"\n{passed} passed, {failed} failed", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
