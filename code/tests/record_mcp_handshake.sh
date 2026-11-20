#!/usr/bin/env bash
# Record what a real MCP client sends when it connects.
#
#   bash code/tests/record_mcp_handshake.sh [path-to-liwenjson]
#
# The audit asked for at least one mandatory host integration verified against a
# real client session (marks/迭代.md §8.3). This records the client's side of the
# handshake: a `tee` wrapper around `liwenjson mcp` is registered with
# `claude mcp add`, the client connects, and its requests land in
# `code/llm/fixtures/real_client_handshake.jsonl`.
#
# It needs the `claude` CLI on PATH and a logged-in session. It never runs in CI;
# the recorded file is replayed by `code/tests/mcp_client_replay.py`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${1:-$ROOT/code/_build/native/release/build/cmd/liwenjson/liwenjson.exe}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/liwenjson-handshake.XXXXXX")"
trap 'claude mcp remove liwenjson-handshake -s local >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }
command -v claude >/dev/null || { echo "the claude CLI is not on PATH" >&2; exit 2; }

cat > "$WORK/wrap.sh" <<WRAP
#!/bin/sh
tee "$WORK/client-in.log" | "$BIN" mcp | tee "$WORK/server-out.log"
WRAP
chmod +x "$WORK/wrap.sh"

cd "$WORK"
claude mcp remove liwenjson-handshake -s local >/dev/null 2>&1 || true
claude mcp add liwenjson-handshake -- "$WORK/wrap.sh" >/dev/null
claude mcp list | grep -F liwenjson-handshake

cp "$WORK/client-in.log" "$ROOT/code/llm/fixtures/real_client_handshake.jsonl"
cp "$WORK/server-out.log" "$ROOT/code/llm/fixtures/real_client_handshake.responses.jsonl"
echo "wrote code/llm/fixtures/real_client_handshake.jsonl"
