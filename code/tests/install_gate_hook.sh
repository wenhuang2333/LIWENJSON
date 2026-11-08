#!/usr/bin/env bash
# Install the InterJSON execution gate as a Claude Code PreToolUse hook.
#
#   bash code/tests/install_gate_hook.sh [project-dir] [--bin path-to-interjson]
#
# The wiring is the one recorded in `test/claude-e2e/`: a `PreToolUse` hook that
# runs the gate on every matching tool call and denies the call when the
# declaration is not satisfied. It is the mandatory half of the gate — the MCP
# tool is advisory, this is not (marks/迭代.md §8.3).
#
# What it does:
#   * copies `.claude/hooks/interjson-gate.sh` into the project;
#   * writes `.claude/interjson-schemas.json` (the declarations) if absent;
#   * adds the `PreToolUse` hook to `.claude/settings.json`, keeping whatever
#     the project already had;
#   * points `env.INTERJSON_BIN` at the binary, because a hook inherits
#     almost no PATH and a bare `interjson` would be exit 127 -- which Claude
#     Code reports and then ignores, so the tool would run ungated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${1:-$PWD}"
BIN="${INTERJSON_BIN:-$ROOT/code/_build/native/release/build/cmd/interjson/interjson.exe}"
[ "${2:-}" = "--bin" ] && BIN="$3"

[ -x "$BIN" ] || { echo "no interjson binary at $BIN" >&2; exit 2; }
command -v jq >/dev/null || { echo "the hook needs jq" >&2; exit 2; }

mkdir -p "$PROJECT/.claude/hooks"
cp "$ROOT/code/tests/claude-e2e/.claude/hooks/interjson-gate.sh" \
   "$PROJECT/.claude/hooks/interjson-gate.sh"
chmod +x "$PROJECT/.claude/hooks/interjson-gate.sh"

if [ ! -f "$PROJECT/.claude/interjson-schemas.json" ]; then
  cp "$ROOT/code/tests/claude-e2e/.claude/interjson-schemas.json" \
     "$PROJECT/.claude/interjson-schemas.json"
  echo "wrote $PROJECT/.claude/interjson-schemas.json (edit it: one declaration per tool)"
fi

settings="$PROJECT/.claude/settings.json"
[ -f "$settings" ] || printf '{\n  "hooks": {}\n}\n' > "$settings"

jq --arg bin "$BIN" '
  .env = ((.env // {}) + {INTERJSON_BIN: $bin})
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
      matcher: "Bash",
      hooks: [{type: "command",
                command: "${CLAUDE_PROJECT_DIR}/.claude/hooks/interjson-gate.sh",
                timeout: 30}]
    }])
' "$settings" > "$settings.new" && mv "$settings.new" "$settings"

cat <<NOTE

installed in $PROJECT:
  .claude/hooks/interjson-gate.sh
  .claude/interjson-schemas.json
  .claude/settings.json  (a PreToolUse hook on Bash, INTERJSON_BIN=$BIN)

Try it:
  cd $PROJECT
  claude -p "Run: touch pwned.txt" --allowedTools Bash
  ls pwned.txt    # must not exist: the gate refused the call

Replay it without a model:
  python3 $ROOT/code/tests/hook_replay.py
NOTE
