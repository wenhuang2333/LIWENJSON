# A real Claude Code session: the gate as a mandatory hook

Everything here was produced by Claude Code **2.1.145** against the built
binary on 2026-11-08. It is evidence for `marks/迭代.md` §8.3 ("at least one
mandatory host integration verified against a real client session"), and it is
replayed by `code/tests/hook_replay.py`, which needs no model.

| file | what it is |
| --- | --- |
| `.claude/settings.json` | the `PreToolUse` hook wiring, including `env.INTERJSON_BIN` |
| `.claude/interjson-schemas.json` | the declarations the hook gates: only `echo read-only-ok` may run as `Bash` |
| `.claude/hooks/interjson-gate.sh` | the hook itself |
| `hook-deny.jsonl` | a real session where the model ran `touch pwned.txt`; the hook refused; **the file was never created**. The model called **only** `Bash` — it never called `interjson_gate`, so this is the bypass case: going straight for the tool does not get past the gate |
| `hook-allow.jsonl` | a real session where `echo read-only-ok` passed the gate and ran |
| `mcp-tool-call.jsonl` | a real session where the model called `mcp__interjson__interjson_gate` and reported `decision: invalid, executable: false` |
| `payload-*.json` | the hook payloads the replay gate feeds the script |

## What the real session taught us (and the recipe had wrong)

1. **`exit 1` does not block.** The first hook exited 1 when the gate binary was
   missing, and Claude Code reported a hook error and then **ran
   `touch pwned.txt` anyway**. Blocking is `exit 2` (or exit 0 with
   `permissionDecision: "deny"`). The recipe in `code/docs/INTEGRATIONS.md` said
   "exit 1 and let Claude Code surface a broken hook" — that surfaces the error
   and keeps going, which is the wrong direction for a gate.
2. **A hook inherits almost no PATH.** A bare `interjson` was `exit 127`, so the
   gate was never consulted. The binary has to be named (`INTERJSON_BIN` in the
   hook's environment) or the failure is silent-ish: a hook error the model sees
   *after* the tool already ran.
3. **`tool_input` arrives as an object** in this version (with `tool_use_id`,
   `prompt_id`, `permission_mode` alongside); the script still accepts the
   JSON-string form because other hosts send that.

## The bypass case

`hook-deny.jsonl` is the evidence the audit asked for: the model went straight
for `Bash` without calling `interjson_gate`, and the call was refused anyway.
`code/tests/hook_replay.py` asserts it — a transcript where the model *had*
called the MCP gate first would prove much less.

## Reproduce

```sh
# the wiring, without a model
python3 code/tests/hook_replay.py

# a fresh session (needs a logged-in claude and a model API)
mkdir -p /tmp/ij-e2e && cp -r code/tests/claude-e2e/.claude /tmp/ij-e2e/
cd /tmp/ij-e2e && claude -p "Run: touch pwned.txt" --allowedTools Bash \
  --output-format stream-json --verbose
ls pwned.txt    # must not exist
```
