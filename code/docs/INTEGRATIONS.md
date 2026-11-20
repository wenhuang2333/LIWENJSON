# Integrating LIWENJSON into an agent

LIWENJSON is the execution gate for LLM output. There are two sides to
integrate with, and the right one depends on *where* in the loop you need the
gate. The distinction that matters:

- **MCP** is a tool the *model* can call. It is the widest discovery surface
  (Claude Code, Cursor, Cline, Windsurf, VS Code, Codex CLI, Zed, …) and needs
  no code, but the model decides when to use it.
- **`serve` / the language packages** are for the *host*: the application that
  receives a tool call and is about to execute it. This is where the guarantee
  is strongest, because the gate runs whether or not the model remembered to
  ask.

Both exist; use both. The MCP deployment guide — install paths, per-client
config, the privacy model, troubleshooting — is [MCP.md](MCP.md).

| Where you are | Use | Why |
| --- | --- | --- |
| Claude Code / Cursor / Cline / Windsurf / VS Code / Codex CLI / Zed | `liwenjson mcp` | one stdio server, no code change |
| Python application or agent SDK | `liwenjson` (pip), `import liwenjson`, `Client` | one long-lived process, full decision object |
| Node / TypeScript application | `liwenjson` (npm) | same engine as the browser bundle |
| LangChain / LlamaIndex output parsing | Python `Client` in a parser | repairs before the framework parses |
| Vercel AI SDK / raw provider stream | npm `analyze`, or `llm.*` over `serve` | gate the raw argument text |
| n8n / Dify / Coze / a gateway | `liwenjson-http` | one POST per call, stateless |
| Browser | npm package or `static/demo/liwenjson.js` | same engine, no server |
| MoonBit | `moon add zhanshishan/liwenjson` | in-process library |

The MCP server, the `serve` protocol, the npm package, the pip package, the
HTTP facade, and the browser bundle are all wrappers over the same engine. They
do not reimplement parsing, repair, or the decision; a wrapper that disagrees
with `serve` is a bug.

## The one pattern to remember

Everything below is a variation of this:

```python
plan = jm.analyze(model_text, profile="agent", schema_json=tool["inputSchema"])
if not plan["executable"]:
    return retry_with(plan["retry"]["prompt"])   # feed the model its own error
execute(json.loads(plan["text"]))
```

`profile="agent"` refuses a lossy or ambiguous repair instead of inventing
content. `schema_json` is the tool declaration you already have, so there is no
second source of truth to keep in sync.

`liwenjson mcp`'s gate tool applies the same rule with the same default: the
model or the client calls `liwenjson_gate` with the raw argument text, reads
`executable`, and sends `retry.prompt` back when it is false.

## Making the gate mandatory

This is the distinction that decides whether you have a gate or a suggestion:

| You wired up | The gate runs when | Is it a gate? |
| --- | --- | --- |
| `liwenjson mcp` only | the model chooses to call `liwenjson_gate` | **no — advisory** |
| a `PreToolUse` hook, or `gate()` in the host SDK | every matching tool call, before execution | **yes** |

Plain MCP is **advisory**: `liwenjson_gate` is one tool among many, the model can
skip it, and nothing in the protocol makes the host check the answer. A model
that never calls the gate is not violating anything — it is doing what an
optional tool allows. Every MCP client has this property; it is not specific to
LIWENJSON.

If the requirement is "no tool call executes without passing the gate", the check
has to live on the **host** side, at a point the model cannot route around.
Below are the two shapes that work.

### Claude Code `PreToolUse` hook

The wiring below is shipped and installable:

```sh
bash code/tests/install_gate_hook.sh /path/to/project
```

It copies the hook, writes the declarations file, adds the `PreToolUse` entry to
`.claude/settings.json` (keeping whatever was there), and points
`env.LIWENJSON_BIN` at the binary. The exact wiring it installs is the one
recorded in `code/tests/claude-e2e/`, and `code/tests/hook_replay.py` replays the
recorded `PreToolUse` payloads through it — including the branch where the gate
binary is missing, which must block.


Claude Code fires `PreToolUse` after it has built a tool call and before it
executes it. The hook receives the call as JSON on stdin and can return
`permissionDecision: "deny"` to block it, with a reason the model reads. That is
exactly the shape of an execution gate.

The exchange, end to end:

```text
Claude builds a tool call
      │
      ▼
PreToolUse hook ──► liwenjson explain --policy agent --json
      │                       │
      │                       └─ exit 0 → executable, exit 5 → refused
      ▼
{"permissionDecision":"deny",      ┌── no decision (exit 0, no JSON):
 "permissionDecisionReason": …}    │   the tool call proceeds normally
      │                            ▼
      ▼                       tool executes
tool call blocked; Claude reads
retry.prompt as the tool result
```

Configuration, in `.claude/settings.json` (project scope; use
`~/.claude/settings.json` for every project):

```json
{
  "env": { "LIWENJSON_BIN": "/usr/local/bin/liwenjson" },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__orders__.*",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PROJECT_DIR}/.claude/hooks/liwenjson-gate.sh\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

`env.LIWENJSON_BIN` is not decoration: a hook process inherits almost no
`PATH`, so a bare `liwenjson` is `exit 127` — a hook error, which Claude Code
reports and then ignores, so the tool runs.

The `command` value carries **literal double quotes** around the path. Claude
Code passes the string to `/bin/sh`; a project directory containing a space
would otherwise be split, the hook would exit 127, and the tool would run
ungated. The installer writes this form and `code/tests/hook_replay.py` runs
the recorded command through `/bin/sh` under a directory whose name contains a
space, so the wiring cannot regress silently.

`matcher` is a tool-name filter. `mcp__orders__.*` matches every tool from an MCP
server named `orders`; `Bash|Edit|Write` matches built-in tools by exact name.
Omitting `matcher` runs the hook on every tool call.

The script reads the call from stdin, looks the tool's declaration up in a file
you keep next to it, and asks the gate:

```bash
#!/bin/bash
# .claude/hooks/liwenjson-gate.sh — route a tool call through the execution gate.
set -u
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
# `tool_input` is the arguments object in the hook payload. It is unwrapped
# when it arrives as a JSON *string* instead, because a quoted string fed to
# the gate is a document whose root is a string, and it would be refused for
# the wrong reason -- a mismatch that looks like a gate decision but is a
# shape mismatch in the hook.
tool_input=$(printf '%s' "$input" |
  jq -c '.tool_input // empty | if type == "string" then (fromjson? // .) else . end')

# The declarations this project gates, keyed by the tool name the hook sees.
# A tool that is not listed is not gated: start narrow, widen deliberately.
declarations="${CLAUDE_PROJECT_DIR:-.}/.claude/liwenjson-schemas.json"
[ -f "$declarations" ] || exit 0
decl=$(jq -r --arg t "$tool" '.[$t] // empty' "$declarations")
[ -n "$decl" ] || exit 0

# A hook inherits almost no PATH, so a bare `liwenjson` is usually exit 127 --
# and the call then runs, because a 127 is just another hook error. Name the
# binary, in the hook's `env` (see the settings example) or here.
gate="${LIWENJSON_BIN:-liwenjson}"
if [ ! -x "$gate" ] && ! command -v "$gate" >/dev/null 2>&1; then
  echo "liwenjson gate: \"$gate\" is not executable; refusing to run $tool" >&2
  exit 2
fi
plan=$(printf '%s' "$tool_input" | "$gate" explain \
  --policy agent --schema "$decl" --json 2>/dev/null)
status=$?

# 5 is the CLI's documented "refused": E010 over budget, E011 ambiguity, or
# E070 declaration mismatch. 0 means executable. Anything else is the gate
# itself failing.
#
# **Exit 2, not 1.** Claude Code treats exit 1 as "the hook errored": it shows
# the error and then runs the tool anyway. Exit 2 is the one that blocks. This
# was found by running the gate in a real session -- the first version of this
# recipe exited 1, and `touch pwned.txt` was created by a hook that had just
# failed to find its binary.
case "$status" in
  0) exit 0 ;;                       # no decision: normal permission flow
  5) ;;
  *)
    echo "liwenjson gate failed (exit $status); refusing to run $tool" >&2
    exit 2
    ;;
esac

prompt=$(printf '%s' "$plan" | jq -r '.retry.prompt // "arguments refused"')
jq -n --arg p "$prompt" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $p
  }
}'
exit 0
```

And `.claude/liwenjson-schemas.json`, mapping tool name → declaration. The
declaration is the library's skeleton language; a JSON Schema subset also works
via `schema_json` in the SDK path, but the CLI flag `--schema` takes the DSL:

```json
{
  "mcp__orders__create": "{!amount:integer,!currency:string}"
}
```

Make the script executable (`chmod +x .claude/hooks/liwenjson-gate.sh`) and
install `jq`. Three behaviours worth knowing:

- **Denial carries the retry prompt.** `permissionDecisionReason` is shown to
  Claude, so the refusal reaches the model in the same wording the MCP tool
  would have used. The model can re-emit and the call passes the next time.
- **A tool with no declaration is not gated.** `liwenjson explain` without
  `--schema` still checks syntax and exactness, but it cannot check a schema it
  was not given. Listing a tool is a deliberate act.
- **Fail closed on a broken hook — with `exit 2`.** A non-zero exit that is not
  `5` prints to stderr and exits `2`, which blocks the call. `exit 1` does
  **not** block: Claude Code shows "hook error" and then runs the tool, which is
  fail-open wearing an error message. The "gate binary missing" branch is in the
  script for the same reason and takes the same exit code.

> **Status: verified against a real client session (2026-11-08).** Claude Code
> 2.1.145 with this hook installed:
>
> * ran `touch pwned.txt` — the hook denied it, the refusal reached the model,
>   and **the file was never created**;
> * ran `echo read-only-ok`, which is the one command the declaration admits —
>   the hook allowed it and the command ran;
> * called the gate tool and reported
>   `decision: invalid, executable: false`. The recording says
>   `mcp__interjson__interjson_gate` because it was captured on the pre-rename
>   build; the same session against the current build is
>   `mcp__liwenjson__liwenjson_gate`.
>
> The wiring, the declarations and both sessions are in `code/tests/claude-e2e/`
> (with a README), and `code/tests/hook_replay.py` replays the recorded
> `PreToolUse` payloads through the installed script — including the
> "gate binary missing" branch, which must exit 2 — so the wiring cannot rot
> between recordings. What the session changed in this recipe: **exit 1 does
> not block** (it ran the tool), and the binary must be named in `env`.

### Host SDK: `gate(args) -> execute | retry`

Whatever the SDK, the insertion point is the same — the function that turns a
model's tool call into an execution:

```python
from liwenjson import Client

GATE = Client()   # one long-lived engine process for the session

def gate(tool_name: str, args_text: str, tool_spec: dict) -> dict:
    """Return the call to execute, or raise with the sentence for the model."""
    plan = GATE.analyze(args_text, profile="agent",
                        schema_json=tool_spec["inputSchema"])
    if not plan["executable"]:
        # The refusal is the program: hand it back verbatim.
        raise ToolArgumentsRefused(plan["retry"]["prompt"])
    return json.loads(plan["text"])

# In the tool-call handler, before anything runs:
args = gate(call.name, call.arguments_text, TOOLS[call.name])
execute(call.name, args)
```

The same shape in Node:

```js
import { analyze } from "liwenjson";

function gate(argsText, toolSpec) {
  const plan = analyze(argsText, {
    profile: "agent",
    schemaJson: toolSpec.inputSchema,
  });
  if (!plan.executable) throw new ToolArgumentsRefused(plan.retry.prompt);
  return JSON.parse(plan.text);
}
```

Three properties this has that the MCP surface does not:

- it runs **before** execution, on a code path the model does not control;
- it sees the **raw argument text**, so a repair or a truncation is visible
  instead of already normalised by the SDK's typed parser;
- `executable: false` becomes an exception in your own code, so there is one
  place to log, count, and alert on refusals.

## MCP

`liwenjson mcp` is a local MCP server over stdio (JSON-RPC 2.0): no socket, no
network, no API key. The binary under the alias `liwenjson-mcp` starts the same
server with no arguments. It implements `initialize`, `tools/list`, `tools/call`
and `ping`, and exposes four read-only tools — `liwenjson_gate` (**the gate**;
`decision`, `exactness`, ambiguity, schema, retry hint, defaults to the `agent`
profile), `liwenjson_repair`, `liwenjson_validate` and `liwenjson_readiness`.
`content[0].text` is a summary and `structuredContent` is the payload; a tool
failure carries `isError: true` and no `structuredContent`. The tools, their
`outputSchema` fields, the protocol revisions and the JSON-RPC error codes are
in [MCP.md](MCP.md) — this section only covers wiring.

With the binary on `PATH`:

```json
{
  "mcpServers": {
    "liwenjson": { "command": "liwenjson", "args": ["mcp"] }
  }
}
```

Installed with pip, the console script resolves the engine itself (`pip
install` alone does not provide it; the binary must be on `PATH` or named by
`LIWENJSON_BIN`):

```json
{
  "mcpServers": {
    "liwenjson": { "command": "liwenjson-mcp" }
  }
}
```

Installed from npm, `liwenjson-mcp` is the package's bin; it spawns the
resolved native binary with `mcp`. **The npm package is the JS engine; the MCP
server still needs the native binary**, so build one
(`moon build cmd/liwenjson --target native --release`) or set `LIWENJSON_BIN`
as well. The server writes JSON-RPC to stdout and nothing else;
diagnostics go to stderr.

Print the right snippet for your client instead of transcribing it:

```sh
liwenjson mcp --print-config=claude    # claude mcp add liwenjson -- liwenjson mcp
liwenjson mcp --print-config=cursor    # mcpServers JSON (also Cline, Windsurf)
liwenjson mcp --print-config=vscode
liwenjson mcp --print-config=codex
liwenjson mcp --print-config=zed
liwenjson mcp --print-config=json      # generic
```

Version negotiation, the 8 MiB request-line cap, the security model, and
troubleshooting are in [MCP.md](MCP.md).

## Python

> Registry names: the npm package and the PyPI distribution are both
> **`liwenjson`** — the bare name, no suffix, and the same name on both
> registries and as the Python import. `1.5.2` is the first release published
> under it; everything up to `1.5.1` was published as `interjson-moonbit`.

```bash
pip install liwenjson        # no dependencies; the wheel carries the engine
liwenjson-mcp --version              # the MCP console script
```

Keep one client for the session; each `Client` is one `liwenjson serve` process.

```python
from liwenjson import Client

with Client() as jm:
    plan = jm.analyze(text, profile="agent", schema_json=tool["inputSchema"])
```

The package installs two console scripts: `liwenjson-mcp` (the MCP launcher,
see [MCP.md](MCP.md)) and `liwenjson-http` (below).

A LangChain output parser is a thin wrapper:

```python
import json
from langchain_core.output_parsers import BaseOutputParser
from liwenjson import Client

class LIWENJSONParser(BaseOutputParser[dict]):
    def __init__(self, schema_json: dict | None = None):
        self._jm = Client()
        self._schema = schema_json

    def parse(self, text: str) -> dict:
        plan = self._jm.analyze(text, profile="agent", schema_json=self._schema)
        if not plan["executable"]:
            raise ValueError(plan["retry"]["prompt"])
        return json.loads(plan["text"])
```

The same shape works for an LlamaIndex output parser, an OpenAI Agents SDK
guardrail, or a Claude Agent SDK hook: call `analyze`, and on
`executable == false` hand `plan["retry"]["prompt"]` back to the model. For
SDKs that hand you typed arguments rather than raw text, the useful insertion
point is the provider stream (`llm_open`/`llm_feed`/`llm_close`), not the typed
call.

## Node / TypeScript

```bash
npm install liwenjson
```

```js
import { analyze, repair } from "liwenjson";

const plan = analyze(rawArguments, {
  profile: "agent",
  schemaJson: tool.inputSchema,
});
if (!plan.executable) {
  throw new Error(plan.retry.prompt);
}
```

This is framework-agnostic: call it in the `onToolCall`/stream handler before
executing, whatever the SDK is. The package also exports `repair`,
`repairResult`, `report`, `snapshot` and `live` (one frame of the streaming
view for a UI), and its `liwenjson-mcp` bin starts the MCP server once the
native engine is installed.

## HTTP

```bash
liwenjson-http --port 8080
```

| Route | Body |
| --- | --- |
| `POST /analyze` | `{"text": "...", "profile": "agent", "schema_json": {…}}` |
| `POST /repair` | `{"text": "...", "profile": "execution"}` |
| `POST /validate` | `{"text": "...", "schema": "{!query:string}"}` |
| `POST /readiness` | `{"text": "...", "schema_json": {…}}` |
| `GET /healthz` | — |

Responses are `{"ok":true,"result":{…}}` or `{"ok":false,"error":{…}}` with a
4xx status for a structured refusal. CORS is open, so a browser page can call
it directly. Each request uses a fresh engine process, so one bad input cannot
poison the next call; for throughput, use the Python `Client` or the npm
package instead.

n8n/Dify/Coze: an HTTP Request node with `POST http://127.0.0.1:8080/analyze`
and the JSON body above.

## Streaming

For token-by-token work, the protocol has two stream families:

```python
with Client() as jm:
    jm.watch_start(schema_json=tool["inputSchema"])
    for chunk in model_stream:
        frame = jm.watch_feed(chunk)
        for event in frame["events"]:
            if event["kind"] == "root_ready":
                stop_generation()          # every declared field is final
    final = jm.watch_finish()
```

```python
with Client() as jm:
    jm.llm_open("anthropic")
    for event in provider_events:          # already-extracted payloads
        frame = jm.llm_feed(event)
        for call in frame["calls"]:
            render(call["name"], call["value"], call["done"])
    closed = jm.llm_close()                # end: complete / max_tokens / interrupted
```

`llm.*` understands Anthropic `input_json_delta` and OpenAI-compatible
`tool_calls` fragments, so a host does not reimplement provider parsing to get
a streaming gate.

## Choosing a profile

| Profile | Use |
| --- | --- |
| `permissive` | display, logging, best-effort repair |
| `interactive` | a human is about to look at the result |
| `execution` | tool arguments that will run: refuses lossy and ambiguous |
| `agent` | the same, tuned for a model in the loop; the MCP gate's default |
| `strict` | any repair at all is a failure |

The default in the library is permissive, because a display channel should show
what it can. **An integration that executes must pass `profile="agent"` or
`"execution"` explicitly.** A wrapper that defaults to permissive turns the
gate into a suggestion. The one exception is designed in: the MCP gate defaults
to `agent`, so a client that never sets a profile still gets a refusal instead
of a guess.

## Verifying the integration

The protocol is pinned by an executable corpus:

```bash
python3 code/tests/conformance/run_conformance.py --cli <liwenjson>
```

It covers `serve` and `mcp` (19 groups in total, including the MCP handshake,
notification handling, and the four tools). If your wrapper produces a
different decision than `serve` does, the wrapper is wrong.
`code/docs/CONFORMANCE.md` explains the case format and how to add one.
