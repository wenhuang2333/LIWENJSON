#!/bin/bash
# PreToolUse execution gate: a tool call runs only if the gate says it may.
#
# The real-session wiring, as verified: Claude Code 2.1.145 sends the call as
# JSON on stdin and honours a `permissionDecision: "deny"` hook result. Two
# details were wrong in the first version of this script and are load-bearing:
#
#   * `LIWENJSON_BIN` must point at a real binary. A hook inherits almost no
#     PATH, so a bare `liwenjson` is exit 127 -- and Claude Code *runs the tool
#     anyway* when the hook exits 1, which is the opposite of a gate.
#   * a broken gate must exit **2**. Exit 1 is "the hook errored", which Claude
#     Code reports and then ignores; exit 2 is "block this call". The first
#     version exited 1, and `touch pwned.txt` was created anyway.
set -u
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# `tool_input` is the arguments object; some hosts send it as a JSON string.
# Feeding the string form to the gate makes the document's root a string, which
# is refused for the wrong reason.
tool_input=$(printf '%s' "$input" |
  jq -c '.tool_input // empty | if type == "string" then (fromjson? // .) else . end')

declarations="${CLAUDE_PROJECT_DIR:-.}/.claude/liwenjson-schemas.json"
[ -f "$declarations" ] || exit 0
decl=$(jq -r --arg t "$tool" '.[$t] // empty' "$declarations")
# A tool this project does not declare is not gated. Gating everything by
# accident makes the hook unusable; listing a tool is a deliberate act.
[ -n "$decl" ] || exit 0

gate="${LIWENJSON_BIN:-liwenjson}"
if [ ! -x "$gate" ] && ! command -v "$gate" >/dev/null 2>&1; then
  echo "liwenjson gate: \"$gate\" is not executable; refusing to run $tool" >&2
  exit 2
fi

plan=$(printf '%s' "$tool_input" | "$gate" explain --policy agent --schema "$decl" --json 2>/dev/null)
status=$?
case "$status" in
  0) exit 0 ;;                       # no decision: normal permission flow
  5) ;;                              # the documented "refused"
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
