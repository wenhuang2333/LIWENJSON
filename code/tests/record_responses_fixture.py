#!/usr/bin/env python3
"""Record a real Responses-API stream into the adapter's fixture set.

The audit (marks/迭代.md §3.5) asked for one thing above the code fix: *put a
real, desensitised stream into the fixtures*. A synthetic stream proves the
routing logic; a recorded one proves the wire format, and the Responses protocol
is the one that was silently dropped.

    python3 test/record_responses_fixture.py            # needs the real backend
    python3 test/record_responses_fixture.py --dry-run  # show what it would write

It writes two files:

  code/llm/fixtures/live_responses_tool_call.sse       the raw bytes, verbatim
  code/llm/fixtures/live_responses_tool_call.jsonl     one event payload per line
  code/llm/fixtures/live_responses_tool_call.provenance.json

The response id, the call id and the item id are replaced with stable
placeholders; nothing else is touched. The arguments, the event order and the
event types are exactly what the provider sent, which is the point: a future
hand-written "improvement" of the reader has to survive these bytes.

The fixture is replayed by `code/tests/run_llm_loopback.py`, which also
byte-compares a re-record; and by `moon test` through the embedded copy that
`tests/gen_llm_fixtures.py --record-responses` produces.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
FIXDIR = ROOT / "code" / "llm" / "fixtures"
# The endpoint and the key are read from the environment first and from the
# workspace's own note file second. The key is never written anywhere.
CONFIG = Path(os.environ.get("LIWENJSON_PROVIDER_CONFIG", ROOT / "AI 后端.txt"))
NAME = "live_responses_tool_call"

BASE = os.environ.get("LIWENJSON_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LIWENJSON_API_KEY", "")
MODEL = os.environ.get("LIWENJSON_MODEL", "")
if not (BASE and KEY and MODEL):
    config = CONFIG.read_text(encoding="utf-8")
    BASE = BASE or re.search(r"请求地址：(\S+)", config).group(1).rstrip("/")
    KEY = KEY or re.search(r"密钥：(\S+)", config).group(1)
    MODEL = MODEL or re.search(r"模型名称：(\S+)", config).group(1)

SCHEMA = {
    "type": "object",
    "properties": {
        "location": {"type": "string"},
        "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
    },
    "required": ["location"],
    "additionalProperties": False,
}

TOOLS = [
    {
        "type": "function",
        "name": "get_weather",
        "description": "Report the weather for a city",
        "parameters": SCHEMA,
    }
]

PROMPT = (
    "Call get_weather exactly once with location Paris and unit celsius. "
    "Do not explain."
)


def request_stream() -> tuple[str, list[dict]]:
    body = {
        "model": MODEL,
        "input": PROMPT,
        "tools": TOOLS,
        "tool_choice": "required",
        "max_output_tokens": 400,
        "stream": True,
    }
    req = urllib.request.Request(
        BASE + "/responses",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as response:
        raw = response.read().decode("utf-8")
    events = []
    for block in re.split(r"\r?\n\r?\n", raw):
        data = "\n".join(
            line[5:].lstrip() for line in block.splitlines() if line.startswith("data:")
        )
        if data and data != "[DONE]":
            events.append(json.loads(data))
    return raw, events


def desensitise(raw: str, events: list[dict]) -> tuple[str, list[dict]]:
    """Replace the identifiers that belong to one account's response.

    The *shape* of an id is kept (`call_00_…`, `fc_…`) because the reader's
    identity logic is what is being tested; only the unique part is replaced.
    """
    subs: dict[str, str] = {}

    def sub(value: str, replacement: str) -> None:
        if value and value not in subs:
            subs[value] = replacement

    for event in events:
        item = event.get("item") or {}
        rid = (event.get("response") or {}).get("id")
        if isinstance(rid, str):
            sub(rid, "resp_fixture")
        for key in ("item_id", "call_id"):
            if isinstance(item.get(key), str):
                sub(item[key], "fc_fixture" if key == "item_id" else "call_fixture")
            if isinstance(event.get(key), str):
                sub(event[key], "fc_fixture" if key == "item_id" else "call_fixture")
        if isinstance(item.get("id"), str):
            sub(item["id"], "fc_fixture")
        # The chat-completions-style id some gateways add.
        if isinstance(event.get("id"), str) and event.get("object"):
            sub(event["id"], "chatcmpl-fixture")

    text = raw
    for real, placeholder in subs.items():
        text = text.replace(real, placeholder)
    clean = [json.loads(line) for line in _data_lines(text)]
    return text, clean


def _data_lines(raw: str) -> list[str]:
    out = []
    for block in re.split(r"\r?\n\r?\n", raw):
        data = "\n".join(
            line[5:].lstrip() for line in block.splitlines() if line.startswith("data:")
        )
        if data and data != "[DONE]":
            out.append(data)
    return out


def main() -> int:
    dry = "--dry-run" in sys.argv
    raw, events = request_stream()
    if not events:
        print("no events came back; nothing recorded", file=sys.stderr)
        return 1
    text, clean = desensitise(raw, events)
    kinds = [e.get("type", "") for e in clean]
    terminal = [
        e.get("type")
        for e in clean
        if e.get("type") in ("response.completed", "response.incomplete", "response.failed")
    ]
    print(f"events: {len(clean)}; terminal: {terminal}")
    print("event types:", ", ".join(dict.fromkeys(kinds)))
    if dry:
        return 0

    FIXDIR.mkdir(parents=True, exist_ok=True)
    (FIXDIR / f"{NAME}.sse").write_text(text, encoding="utf-8")
    (FIXDIR / f"{NAME}.jsonl").write_text(
        "\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in clean)
        + "\n",
        encoding="utf-8",
    )
    (FIXDIR / f"{NAME}.provenance.json").write_text(
        json.dumps(
            {
                "fixture": NAME,
                "model": MODEL,
                "endpoint": BASE + "/responses",
                "protocol": "openai-responses",
                "prompt": PROMPT,
                "tools": TOOLS,
                "transport": "live-http-sse",
                "vendor_capture": True,
                "recorded_by": "test/record_responses_fixture.py",
                "desensitised": "response/item/call ids replaced; nothing else changed",
                "events": len(clean),
                "terminal": terminal,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"wrote {FIXDIR / NAME}.sse, .jsonl, .provenance.json")

    # And prove the adapter reads it back, which is the only reason to record it.
    cli = ROOT / "code/_build/native/release/build/cmd/liwenjson/liwenjson.exe"
    proc = subprocess.run(
        [str(cli), "llm", "--provider", "openai-responses", "--sse"],
        input=text,
        text=True,
        capture_output=True,
        timeout=60,
    )
    print("adapter rc:", proc.returncode)
    print(proc.stdout.strip())
    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
