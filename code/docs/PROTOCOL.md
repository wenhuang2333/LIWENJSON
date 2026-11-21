# LIWENJSON protocol v1 (`liwenjson serve`)

This is the wire contract behind the Python client, the npm package's future
streaming path, the HTTP facade, and any integration that cannot link the
MoonBit library directly. It is deliberately small: one request object per
line in, one response object per line out.

The one-shot CLI and the library are not replaced by this protocol; they are
the same engine. `liwenjson repair` and `{"method":"repair"}` must produce the
same text, and the conformance suite (`tests/conformance/cases.jsonl`) pins
that.

## Relationship to MCP

This document is the contract for `liwenjson serve`: the **host-side** transport.
`liwenjson mcp` is the **model-side** transport — it speaks MCP (JSON-RPC 2.0 over
stdio, protocol `2025-06-18`, with `2025-03-26` and `2024-11-05` accepted) and
exposes the same engine as four read-only tools: `liwenjson_gate` (primary,
defaults to the `agent` profile, which equals `Options::for_agent()` including
`skip_prose`), `liwenjson_repair`, `liwenjson_validate` and
`liwenjson_readiness`.

The two are separate transports over one engine, not two implementations: a
host that gates tool arguments itself drives `serve` from its own code, while a
host that wants the model to be able to ask for the gate exposes `mcp` and lets
the model call the tools. Both return the same decisions because both call the
same engine. The difference that matters is enforcement: `serve` runs on a code
path the host controls, so the gate always runs; `mcp` is a tool the model may
decline to call, so on its own it is advisory. See
[INTEGRATIONS.md](INTEGRATIONS.md#making-the-gate-mandatory). The MCP methods (`initialize`, `tools/list`, `tools/call`,
notifications) and the per-client configuration are documented in
[MCP.md](MCP.md); `serve` does not implement them.

## Transport

| Property | Value |
| --- | --- |
| Framing | newline-delimited JSON (JSONL), UTF-8 |
| Direction | one request per line on stdin, one response per line on stdout |
| stdout | protocol messages only; never a banner or a log line |
| stderr | diagnostics; never part of the contract |
| Max line | 8 MiB (8 388 608 bytes). Longer lines get a structured `E050` and are discarded through the next LF |
| Concurrency | one active `watch` stream and one active `llm` stream per connection |
| State | `repair` / `analyze` / `validate` / `readiness` are stateless |

A client that only needs one-shot calls can start the process per call (about
2 ms on an Apple M5) or keep one process for a whole session. The `hello`
result advertises `streams: 1` so the single-stream limit is visible rather
than discovered.

## Versioning

Three version numbers are deliberately separate:

| Field | Meaning |
| --- | --- |
| `protocol` | this document; a major change is `2` |
| `engine` | the code version (`moon.mod`, the CLI, the npm/pip packages) |
| `registry` | the version published on mooncakes.io, which currently only accepts `0.x.y` |

`engine` and `registry` can differ; the bytes are the same. A client that
checks compatibility must check `protocol`.

## Handshake

Request:

```json
{"id":1,"method":"hello"}
```

Response:

```json
{"id":1,"ok":true,"result":{"name":"liwenjson","engine":"1.1.0","registry":"0.8.0","protocol":1,"capabilities":["repair","analyze","validate","readiness","watch","llm"],"streams":1}}
```

`id` is chosen by the client, may be a number or a string, and is echoed
unchanged. Unknown response fields must be ignored by clients; unknown request
fields must be ignored by the server (they are forward-compatible hints).

## Response envelope

Success:

```json
{"id":7,"ok":true,"result":{…}}
```

Failure:

```json
{"id":7,"ok":false,"error":{"code":"E011","message":"…","exit":5,"offset":14,"retry_hint":"…"}}
```

`code` is the same `E` code the library raises. `exit` is the CLI exit code
that corresponds to it, so a subprocess-based client and a protocol client
classify failures the same way. `retry_hint`, when present, is the exact text
`RetryHint::to_prompt()` produces; it can be sent back to the model unchanged.

## Methods

### `repair`

```json
{"id":2,"method":"repair","params":{"text":"{a:1,}","profile":"execution"}}
```

`params`: `text` (required), `profile`, `schema`, `schema_json`, `skip_prose`,
`max_loss`.

Result: `text`, `exactness` (`exact`/`cosmetic`/`lossy`), `ambiguous`,
`completeness` (`empty`/`partial`/`complete`), `repairs[]`,
`repairs_truncated`.

Each repair record has exactly the fields `repair_record_fields()` names, and
`repair_record_json()` is the only writer of them — `analyze`, `repair`,
`validate` and the MCP tools all emit the same shape:

| field | meaning |
| --- | --- |
| `rule` | the rule code, `R001`–`R022` |
| `name` | the rule name, e.g. `RemoveExtraComma` |
| `action` | `remove` / `replace` / `insert` / `append_text` / `close` / `merge` / `synthesize` |
| `offset`, `line`, `column` | where it happened, 1-based line/column, 0-based offset |
| `severity` | `info` or `warning` (`warning` = information was lost) |
| `ambiguity` | `unambiguous`, `bare_word`, `adjacent_strings`, `concat_operator` or `trailing_content` |
| `confidence` | the class word: `certain`, `probable`, `ambiguous` or `refused` |
| `confidence_value` | its numeric spelling: `1.0`, `0.75`, `0.5`, `0.0` |
| `information_loss` | `true` for a `warning` record |
| `message` | the rule's own sentence |

Before 1.5.2 the two serialisers had drifted: `repair`/`validate` wrote
`code`/`threshold`/`message` and `analyze` wrote `rule`/`name`/`confidence`,
so a client that read one could not read the other, and the MCP tools returned
a record their own published `outputSchema` did not describe.

A fatal condition is the error envelope, not a partial result. A lossy or
ambiguous repair that the profile refuses is also an error (`E010`/`E011`).

### `analyze`

The decision call. Same params as `repair`, plus `with_text` (default
`false`): `text` is the rendered form of `value`, so sending both puts two
copies of the document on the wire, and it is therefore opt-in.

**Never raises for model output.** A malformed document is `ok: true` with
`decision: "invalid"` and a `retry` prompt. **A host declaration that cannot be
enforced *is* fatal**: an unsupported keyword, an unsatisfiable bound, a
`schema_json` that is not a schema — those are `E070` in the error envelope,
because the model cannot fix them and sending them to the model is a loop that
never converges (audit §4.1).

Result: the complete `RepairPlan` object — `decision`, `label`, `exactness`,
`ambiguous`, `information_loss`, `valid_json`, `normalized`, `ambiguity`,
`execution`, `executable`, `business_authorized`, `syntax_ready_permille`,
`schema_total`, `schema_satisfied`, `schema_missing`, `error`, `repairs`,
`retry`, `refusal`, `repairs_truncated`, `value`, and `text` when `with_text`.

`business_authorized` is always `false`. The gate checks JSON and the declared
schema; it does not canonicalise paths, does not know whether the user may
write the file, and does not know whether the tool is allowed. The label says
`JSON/SCHEMA POLICY PASSED`, not `SAFE TO EXECUTE`, because a label is a
promise and that is the promise this component can keep (audit §7.1).

`refusal` is `null` when `executable` is true; otherwise it names why, so a host
can decide whether an automatic retry is safe without parsing the prompt:

| `kind` | meaning | `auto_retry` |
| --- | --- | --- |
| `syntax` | the text was not a complete, unambiguous document | `true` |
| `schema_or_intent` | the document was complete and conflicts with the declaration | `false` |
| `host_declaration` | the declaration is one this library cannot enforce | `false` |
| `provider` | the model provider refused or filtered the response | `false` |

Only `syntax` is `auto_retry: true`. A retry of a `schema_or_intent` refusal
may come back with a *different action* — that is how a `write` became a `read`
in the audit and was then executed — so the host must look, not loop
(audit §7.2).

### `validate`

```json
{"id":3,"method":"validate","params":{"text":"{a:1,}"}}
```

Result: `valid` (whether the text is legal JSON as written), and
`error` (the first strict-mode refusal) plus `repaired`/`exactness`/`repairs`
when the text is repairable but not valid. With a declaration, a valid
document also gets `schema` (the `SchemaVerdict`: `total`, `satisfied`,
`missing`, `mismatched`, `ok`).

### `readiness`

```json
{"id":4,"method":"readiness","params":{"text":"{\"query\":\"x\",\"limit\":10}","schema":"{!query:string,!limit:integer}"}}
```

Result: `syntax_permille`, `schema_permille`, `settled_permille`, `step`, and
`verdict` (the same `SchemaVerdict`). Without a declaration, only
`syntax_permille` is meaningful (`schema_permille` and `settled_permille` are
`-1`).

### `watch.start` / `watch.feed` / `watch.finish`

The streaming path. One stream at a time.

```json
{"id":5,"method":"watch.start","params":{"schema":"{!a:string}"}}
{"id":6,"method":"watch.feed","params":{"chunk":"{\"a\":\"x\"}"}}
{"id":7,"method":"watch.finish"}
```

`watch.start` result: `ok`, `schema` (the canonical text of the declaration).
`watch.feed` result: `deltas[]` (`path`, `op`, `value`, `text`, `at`),
`events[]` (`kind`, `path`, plus the event payload, `at`, `permille`), and
`bytes` (code units fed). `watch.finish` result: `final` (the same fields as
`repair` plus `value`), `events[]` produced by `finish`, and
`watcher_final` (the readiness watcher's own final parse, or `null`).

`watch.finish` also reports the stream's own account of what it published:
`verdict` (the `SchemaVerdict` of the finished value), `conflict` (whether a
duplicate key re-opened a member after it had been decided, which makes the
earlier events provisional), and `ready_standing` (whether a published
`root_ready` is still true). A host that stops the model on `root_ready` must
check `ready_standing` before executing: the rest of the stream can retract the
promise with `root_invalid`, and `conflict` marks the case where a duplicate key
means the earlier events described a value that no longer exists.

A failed `watch.feed` ends the stream: the parser is finished, so a later
`watch.finish` answers `E030` rather than a partial account. Hosts stop on the
feed error and do not execute anything the stream published before it.

`profile` is honoured; `watch` always enables delta collection internally.

### `llm.open` / `llm.feed` / `llm.close` / `llm.run`

Provider-aware tool-call streams. One stream at a time for the first three.

```json
{"id":8,"method":"llm.open","params":{"provider":"anthropic"}}
{"id":9,"method":"llm.feed","params":{"event":"{\"type\":\"content_block_start\",…}"}}
{"id":10,"method":"llm.close"}
```

`provider` is `anthropic` (default) or `openai` (`openai_compat` is accepted).
`event` is one already-extracted event payload as JSON text; how the bytes left
the provider (SSE, WebSocket, a log line) is the caller's business. `llm.feed`
returns the calls the event touched: `index`, `id`, `name`, `done`,
`exactness`, `end` (`open`/`complete`/`max_tokens`/`interrupted`/
`provider_error`), `stop_reason`, `value`, `open_path`. `llm.close` finishes
every call and adds `error` (the provider's error message, `""` when none) and
`ignored_events`.

`llm.run` is the stateless form: pass `provider` and an `events` array, and it
returns the same object as `llm.close`.

### `shutdown`

```json
{"id":11,"method":"shutdown"}
```

The server answers `{"ok":true,"bye":true}` and exits 0.

## Errors and limits

| Condition | `code` | `exit` |
| --- | --- | --- |
| Malformed request line | `E060` | 3 |
| Missing/invalid parameter | `E050` | 2 |
| Unknown method | `E050` | 2 |
| Line longer than 8 MiB | `E050` | 2 |
| Fatal parse condition | the library's `E` code | 2–5 |

The process never writes a protocol-invalid line. If a handler raises, the
error envelope is the only output for that request; the connection remains
usable.

## Conformance

`tests/conformance/cases.jsonl` is executable documentation: each case pins a
subset of one response, and `run_conformance.py` runs the same corpus on Linux,
macOS and Windows. See [CONFORMANCE.md](CONFORMANCE.md).

## Design notes

- **Why stdio, not wasm or HTTP.** A stdio child works from every language
  without a binding, has no port or authentication surface, and keeps the
  engine in one implementation. A wasm ABI would need a stable C ABI that the
  MoonBit `wasm-gc` target does not promise; HTTP is offered as a thin,
  stateless facade for tools that require it.
- **Why one stream per connection.** Chunked state is where a protocol usually
  grows a map, a lock and a lifetime bug. One stream is enough for a
  tool-calling loop and makes `watch.start`/`finish` a visible state machine.
  A future v2 can add `stream_id` without changing v1 clients.
- **Why `analyze` does not raise.** The gate is useful precisely when the JSON
  is bad; forcing every caller to write a `try` and then re-derive the decision
  would make the safe path the awkward one.
