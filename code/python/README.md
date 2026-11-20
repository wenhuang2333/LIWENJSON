# liwenjson (Python)

LIWENJSON is the **execution gate for LLM output**: it decides whether a model's
JSON may be executed, and when it may not, returns the sentence to send back to
the model. This distribution is the Python client for the MoonBit engine —
streaming repair, partial parsing, and the gate — plus two console scripts, one
of which starts the local MCP server.

No third-party dependencies and nothing else to install: the wheel carries the
engine for every platform the project releases — Linux x86_64 and arm64, macOS
arm64, Windows x86_64 — and picks the right one at import time. The engine is
the same native binary the CLI ships, reached over a versioned stdio protocol.

```bash
pip install liwenjson
```

> The distribution name is **`liwenjson`** on PyPI — the bare name, no suffix —
> and it is also the import name. `1.5.2` is the first release published under
> it; `1.5.1` reached PyPI on 2026-10-30 as `interjson-moonbit`. The npm package
> uses the same name: `npm install liwenjson`.

An engine that is already installed keeps priority: `LIWENJSON_BIN`, then
`liwenjson` on `PATH`, then the bundled binary. Set either to point the client
at a newer CLI than the one this wheel was built with.

```python
import json
from liwenjson import Client

with Client() as jm:
    plan = jm.analyze(
        model_output,
        profile="agent",
        schema_json=tool["inputSchema"],  # the declaration you already have
    )
    if plan["executable"]:
        args = json.loads(plan["text"])
    else:
        print(plan["retry"]["prompt"])    # feed this back to the model
```

`Client` keeps one `liwenjson serve` process alive, so a loop pays the spawn
cost once. `repair`, `analyze` and `validate` are one-shot convenience
functions that spawn a process per call.

## Console scripts

| Script | Use |
| --- | --- |
| `liwenjson-mcp` | Start the local MCP server (stdio, JSON-RPC 2.0) for Claude Code, Cursor, Cline, Windsurf, VS Code, Codex CLI or Zed |
| `liwenjson-http` | Start the stateless HTTP facade (`--port 8080`) |

`liwenjson-mcp` is a launcher, not a server: it resolves the engine and replaces
itself with `<binary> mcp`, so stdin/stdout stay a clean JSON-RPC channel with no
Python in the middle. Resolution order is `LIWENJSON_BIN`, then `liwenjson` on
`PATH`, then the binary this wheel carries for the current platform. Only a
platform the release does not build for — Intel macOS, for example — needs
`LIWENJSON_BIN`.

```bash
liwenjson --version                  # liwenjson 1.5.1: the engine the launchers need
liwenjson-mcp                        # MCP stdio server
liwenjson-mcp --print-config=claude  # the client configuration snippet
liwenjson-http --port 8080           # POST /repair /analyze /validate /readiness, GET /healthz
```

`pip install` installs the client, the two console scripts and the engine.
Nothing has to be on `PATH` for the configuration below to work:

With the engine resolvable, the client configuration is one line:

```json
{
  "mcpServers": {
    "liwenjson": { "command": "liwenjson-mcp" }
  }
}
```

The server exposes four read-only tools: `liwenjson_gate` (the gate:
`executable`, `decision`, `exactness`, `value`, `retry.prompt`),
`liwenjson_repair`, `liwenjson_validate`, and `liwenjson_readiness`. The gate
defaults to the `agent` profile, which equals `Options::for_agent()` — prose
before the arguments is skipped rather than refused. A refused result always
carries a non-empty `retry.prompt` and `value: null`. **MCP is advisory**: the
model can decline to call the gate, so the host must gate the call itself (a
Claude Code `PreToolUse` hook or a host-SDK `gate()` — see
[`docs/INTEGRATIONS.md`](../docs/INTEGRATIONS.md#making-the-gate-mandatory)).

Deployment, per-client configuration, the privacy model and troubleshooting are
in [`docs/MCP.md`](../docs/MCP.md); host-side recipes (LangChain, LlamaIndex,
streaming) are in [`docs/INTEGRATIONS.md`](../docs/INTEGRATIONS.md).

`liwenjson-http` is stateless: one engine process per request, closed after it.
It is the path for n8n, Dify, Coze or a gateway; for throughput, use `Client`.

## Methods

| Method | Returns | Use |
| --- | --- | --- |
| `repair(text, profile=..., schema=...)` | `{text, exactness, ambiguous, repairs, ...}` | repair a document |
| `analyze(text, profile=..., schema=..., schema_json=...)` | the full plan | **the gate**; `executable` decides |
| `validate(text, schema=...)` | `{valid, error?, repaired?, schema?}` | check without repairing |
| `readiness(text, schema=...)` | syntax/schema/settled fractions | when fields become final |
| `watch_start` / `watch_feed` / `watch_finish` | deltas + readiness events | token-by-token |
| `llm_open` / `llm_feed` / `llm_close` | per-tool-call state | Anthropic/OpenAI event streams |

`profile` is one of `permissive`, `interactive`, `execution`, `agent`, `strict`.
`execution` and `agent` refuse a lossy or ambiguous repair instead of
inventing content; `LIWENJSONError` carries `code`, `message`, `exit_code`,
`retry_hint` and `offset`.

`schema` is the library's declaration language (`{!query:string,!limit:integer}`).
`schema_json` is a JSON Schema subset — `type`, `properties`, `required`,
`items`, `enum`, `const`, `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `minLength`, `maxLength`, `pattern` — so a tool's existing
`inputSchema` can be passed directly. Unsupported keywords raise `E070` rather
than being silently dropped.

## Version

The Python package is `1.5.1`, the engine version, published to PyPI on
2026-10-30. The MoonBit package on mooncakes is `0.13.0` because the registry
currently accepts only `0.x.y`; the bytes are the same. `Client.hello()` reports
both. `0.13.0` was published on 2026-10-29, and `0.12.0` (the 1.5.0
correspondence) on 2026-10-28.

License: Apache-2.0.
