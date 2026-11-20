#!/bin/bash
# Runs the CLI over code/examples/cases/*.json and compares stdout with the
# matching .expected file (D12 12.8 step 4).
#
#   bash code/tests/examples.sh [<liwenjson executable>]
#
# Two things are checked per case, not one: the exit code must be 0 *and*
# stdout must equal the .expected file. The old version compared stdout only,
# so a CLI that printed the right text and then failed -- a crash after the
# answer, a broken exit path -- was green. A gate that reads one of the two
# observable outputs is a gate that cannot see the other one fail.
#
# A missing .expected file is a failure, not an empty string: the old
# `cat "$expected"` on a deleted fixture silently compared against nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/_build/native/release/build/cmd/liwenjson/liwenjson.exe}"
# The case directory is overridable so the gate's failure path can be exercised
# in an isolated copy (C-05 negative injection).
CASES="${LIWENJSON_EXAMPLES_DIR:-$ROOT/examples/cases}"

[ -x "$BIN" ] || { echo "error: $BIN not found (build it first)" >&2; exit 2; }
[ -d "$CASES" ] || { echo "error: $CASES not found" >&2; exit 2; }

shopt -s nullglob
inputs=("$CASES"/*.json)
if [ "${#inputs[@]}" -eq 0 ]; then
  echo "error: no *.json cases under $CASES" >&2
  exit 2
fi

pass=0
fail=0
for input in "${inputs[@]}"; do
  name="$(basename "$input" .json)"
  expected="$CASES/$name.expected"
  extra=""
  # 06 is the prose case: it needs the opt-in prose skipper
  [ "$name" = "06-prose" ] && extra="--skip-prose"
  if [ ! -f "$expected" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s\n     missing fixture: %s\n' "$name" "$expected"
    continue
  fi
  want="$(cat "$expected")"
  out="$("$BIN" $extra "$input")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # The text may be right and the run may still be broken. Both are checked.
    fail=$((fail + 1))
    printf 'FAIL %s\n     exit code: %d (must be 0)\n     want: %s\n     got:  %s\n' \
      "$name" "$rc" "$want" "$out"
  elif [ "$out" = "$want" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$name" "$want" "$out"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
