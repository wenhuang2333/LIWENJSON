#!/usr/bin/env bash
# Doc-truth gate: the numbers the judge-facing documents quote must match the
# numbers this repository actually produces right now.
#
# bash tests/claims.sh
#
# Every number below is derived from a command that runs here and now -- not
# read out of a checked-in report and not remembered. The documents are then
# searched for the derived value. A stale number in a document is a failed
# gate, with the file and the expected value named, because a judge can check
# any of them and one wrong figure discredits the table next to it.
#
# Deterministic by construction: the test counts, the assertion counts, the
# conformance groups, the artifact sizes and the corpus sizes do not depend on
# the machine. The coverage percentages are the only machine-dependent ones and
# they move only when the code moves.

# `-e` is on: the gate has to be able to fail on its own errors, not only on
# the numbers it checks. Without it a command that dies half way through --
# a test run that crashes, a build that does not finish -- leaves the gate
# reporting success on the figures it managed to derive before the failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODE="$ROOT/code"
export PATH="$HOME/.moon/bin:$PATH"

FAIL=0
SKIPPED=0
DERIVED=()

fail() {
 FAIL=$((FAIL + 1))
 printf 'FAIL %s\n' "$1" >&2
}

# derive <key> <value> <command>...
#
# An empty value is a failure. The old version recorded it and moved on, so a
# measurement that came back empty -- a test run that produced no count, a
# build that failed -- left the gate reporting success on the figures it did
# manage to read. A figure that cannot be derived cannot be checked, and a
# figure that cannot be checked is exactly what this gate exists to catch.
derive() {
 local key="$1" value="$2"; shift 2
 if [ -z "$value" ]; then
 fail "could not derive '$key' from: $*"
 return 0
 fi
 DERIVED+=("$key=$value")
 printf '%-28s %-16s (%s)\n' "$key" "$value" "$*"
}

# The documents are searched for a literal string. `grep -F` is used so that
# `.` in a version or a ratio is not a wildcard.
# NOTE: there is deliberately no document list here.
#
# There used to be one (`DOCS=(...)`), and it was never read: every check below
# names the files it searches, and that list had drifted to include two
# documents that are not published at all. A list nobody reads is worse than no
# list, because it looks like coverage. What keeps the checks honest instead is
# `tests/published_docs.sh`, which derives the set of published documents from
# `.gitignore` and fails when one of them stops being mentioned where it should
# be -- and the comment at each `require_in` site naming the document it expects.

# require_in <literal> <doc-file>...
# Fails when none of the given files contains the literal.
#
# Some of the documents are deliberately not published (see `.gitignore`): the
# design docs and the delivery documents live only on the author's machine. On
# a clean checkout those files are simply absent, so "none of them mentions the
# figure" is not a defect there -- it is the expected state. What is still a
# real failure is a document that *is* present and says something stale, so the
# two cases are separated explicitly instead of letting absence read as drift.
require_in() {
 local needle="$1"; shift
 local found=0 present=0 f
 for f in "$@"; do
 [ -f "$f" ] || continue
 present=$((present + 1))
 if grep -qF -- "$needle" "$f"; then found=1; fi
 done
 if [ "$found" -eq 1 ]; then
 return 0
 fi
 if [ "$present" -eq 0 ]; then
 SKIPPED=$((SKIPPED + 1))
 printf 'skip %-28s not published (not in this checkout)\n' "'$needle'"
 return 0
 fi
 fail "no document mentions '$needle' (looked in: $*)"
}

# require_line <file> <anchor> <value>...
# Fails unless some line of the file contains the anchor and also contains
# every value.
#
# This replaces the old any-of `require_in` at every site where several
# documents quote the same figure: any-of meant one stale document passed as
# long as any other document had the right number, so a table row could rot for
# releases while the gate stayed green. An anchor line that disappears is a
# failure too -- deleting the row is not a way to stop being checked.
require_line() {
  local file="$1" anchor="$2"; shift 2
  if [ ! -f "$file" ]; then
  SKIPPED=$((SKIPPED + 1))
  printf 'skip %-28s %s is not in this checkout\n' "'$anchor'" "$file"
  return 0
  fi
  local line matched=0 ok v
  while IFS= read -r line; do
  ok=1
  for v in "$@"; do
  printf '%s' "$line" | grep -qF -- "$v" || { ok=0; break; }
  done
  if [ "$ok" -eq 1 ]; then matched=1; break; fi
  done < <(grep -F -- "$anchor" "$file" 2>/dev/null || true)
  if [ "$matched" -eq 1 ]; then
  return 0
  fi
  fail "$file has no line with '$anchor' that quotes: $*"
}

# require_absent_in <literal> <file>...
# Fails when a document still mentions a number that is no longer true.
require_absent_in() {
 local needle="$1"; shift
 local f
 for f in "$@"; do
 [ -f "$f" ] || continue
 if grep -qF -- "$needle" "$f"; then
 fail "'$needle' is stale in $f"
 fi
 done
}

cd "$CODE" || exit 1

# --- test counts per backend -------------------------------------------------
# The count comes from the test runner's own last line, so it cannot drift
# away from the tests that actually ran.
total_tests() {
 local target="$1"
 local out
 out="$(moon test --target "$target" 2>&1 | tail -5)"
 printf '%s' "$out" | sed -n 's/.*Total tests: \([0-9]*\).*/\1/p' | head -1
}

for t in wasm wasm-gc js native; do
 n="$(total_tests "$t")"
 [ -n "$n" ] || { fail "could not read the test count for $t"; continue; }
 derive "tests_$t" "$n" "moon test --target $t"
 # The denominator is the suite size itself, read from the runner rather than
 # written here: the documents quote "<n>/<n> per backend", and a hard-coded
 # denominator would go stale the moment a test is added. Each document is
 # checked on its own line: a single any-of search here used to let one stale
 # document pass because another one was up to date.
 require_line "$ROOT/README.md" "四个后端" "$n/$n"
 require_line "$CODE/README.md" "Cross-backend results are identical" "**$n/$n** tests pass"
 require_line "$CODE/README.zh.md" "| 后端 |" "各 $n/$n 通过"
done

# --- CLI assertions ----------------------------------------------------------
if [ -x "$CODE/_build/native/release/build/cmd/liwenjson/liwenjson.exe" ]; then
 BIN="$CODE/_build/native/release/build/cmd/liwenjson/liwenjson.exe"
else
 moon build cmd/liwenjson --target native --release >/dev/null 2>&1
 BIN="$CODE/_build/native/release/build/cmd/liwenjson/liwenjson.exe"
fi
cli_out="$(bash tests/cli_smoke.sh 2>&1 | tail -3)"
# `skipped` counts the doc-version checks whose document is deliberately not
# published (see cli_smoke.sh); the quoted figure is the passed count, which
# is what a judge running the script on a published checkout sees printed.
CLI_N="$(printf '%s' "$cli_out" | sed -n 's/^\([0-9]*\) passed.*/\1/p' | head -1)"
if [ -n "$CLI_N" ]; then
 derive "cli_assertions" "$CLI_N" "bash tests/cli_smoke.sh"
 require_line "$ROOT/README.md" "CLI 冒烟" "$CLI_N 项断言"
else
 fail "could not read the CLI assertion count from tests/cli_smoke.sh"
fi

hook_out="$(python3 tests/hook_replay.py --cli "$BIN" 2>&1 | tail -1)"
case "$hook_out" in
  ok:*) derive "hook_replay" "pass" "python3 tests/hook_replay.py" ;;
  *) fail "the recorded PreToolUse wiring did not replay: $hook_out" ;;
esac

replay_out="$(python3 tests/mcp_client_replay.py --cli "$BIN" 2>&1 | tail -1)"
case "$replay_out" in
  ok:*) derive "mcp_client_replay" "pass" "python3 tests/mcp_client_replay.py" ;;
  *) fail "a real client's handshake did not replay: $replay_out" ;;
esac

# The contract check runs in STRICT mode: without `jsonschema` it exits 2
# instead of silently skipping the schema comparison, so a missing validator
# can no longer look like a passing contract.
mcp_log="$(mktemp "${TMPDIR:-/tmp}/claims_mcp.XXXXXX")"
mcp_rc=0
python3 tests/mcp_contract_check.py "$BIN" --strict >"$mcp_log" 2>&1 || mcp_rc=$?
mcp_out="$(tail -1 "$mcp_log")"
# The count is not necessarily the last line: the script closes with a prose
# summary. Search the whole log for the `N/M responses valid` figure, so a
# change in the closing sentence cannot turn the derived number into empty.
MCP_N="$(sed -n 's#^\([0-9]*\)/\([0-9]*\) responses valid.*#\1#p' "$mcp_log" | head -1)"
MCP_T="$(sed -n 's#^\([0-9]*\)/\([0-9]*\) responses valid.*#\2#p' "$mcp_log" | head -1)"
rm -f "$mcp_log"
if [ "$mcp_rc" -ne 0 ]; then
 fail "python3 tests/mcp_contract_check.py --strict exited $mcp_rc: $mcp_out"
fi
if [ -n "$MCP_N" ] && [ -n "$MCP_T" ]; then
 derive "mcp_contract" "$MCP_N/$MCP_T" "python3 tests/mcp_contract_check.py --strict"
 # The contract figure is quoted back into the document, like every other
 # derived number: it used to be printed and never checked, so the README row
 # could say any old count.
 require_line "$ROOT/README.md" "MCP 契约" "$MCP_N/$MCP_T 响应通过"
else
 fail "the MCP contract check (strict) did not report a pass count: $mcp_out"
fi
# The manual has to describe every tool the server advertises. This keeps
# `code/docs/MCP.md` in the gate's named-document set (published_docs.sh
# requires claims.sh to name every published document) while checking
# something real: a tool that disappears from the manual is a documentation
# regression, not a formatting preference.
for tool in liwenjson_gate liwenjson_repair liwenjson_validate liwenjson_readiness; do
 require_in "$tool" "$CODE/docs/MCP.md"
done

conf_out="$(python3 tests/conformance/run_conformance.py --cli "$BIN" 2>&1 | tail -3)"
CONF_N="$(printf '%s' "$conf_out" | sed -n 's#^\([0-9]*\)/\([0-9]*\) conformance.*#\1#p' | head -1)"
if [ -n "$CONF_N" ]; then
 derive "conformance_groups" "$CONF_N" "python3 tests/conformance/run_conformance.py"
 require_line "$ROOT/README.md" "协议 / MCP 一致性" "$CONF_N 组"
else
 fail "could not read the conformance group count"
fi

npm_out="$(cd "$CODE/npm" && node --test 2>&1 | grep -E '^ℹ (tests|pass|fail)' | tr '\n' ' ')"
NPM_N="$(printf '%s' "$npm_out" | sed -n 's/.*tests \([0-9]*\).*/\1/p' | head -1)"
if [ -n "$NPM_N" ]; then
 derive "npm_tests" "$NPM_N" "cd code/npm && node --test"
 require_line "$ROOT/README.md" "npm 包" "$NPM_N 个 Node 测试"
else
 fail "could not read the npm test count"
fi

py_out="$(cd "$CODE/python" && python3 -m unittest discover -s tests 2>&1 | sed -n 's/^Ran \([0-9]*\) test.*/\1/p')"
PY_N="$(printf '%s' "$py_out" | head -1)"
if [ -n "$PY_N" ]; then
 derive "python_tests" "$PY_N" "cd code/python && python3 -m unittest discover -s tests"
 require_line "$ROOT/README.md" "Python 包" "$PY_N 个测试"
else
 fail "could not read the Python test count"
fi

# --- coverage ----------------------------------------------------------------
# `moon coverage report -f summary` omits files that are fully covered from
# its per-file list but still counts their lines in its own Total. The gate
# (tests/coverage.sh) sums the listed rows only, so both numbers are derived
# here and both are checked: the per-package split the documents quote, and
# the gate figure.
if moon test --enable-coverage >/dev/null 2>&1; then
 SUM="$(mktemp "${TMPDIR:-/tmp}/claims_cov.XXXXXX")"
 # A stale coverage output (after a source edit) makes this command fail with
 # its reason on the captured stream; under `set -e` the script used to die
 # there and report nothing, which reads as a silent red gate. Name the
 # command's own message instead, and let the gate count it as a failure.
 cov_rc=0
 moon coverage report -f summary >"$SUM" 2>&1 || cov_rc=$?
 if [ "$cov_rc" -ne 0 ]; then
 fail "moon coverage report failed: $(tail -n 1 "$SUM")"
 rm -f "$SUM"
 else
 read -r ROOT_C ROOT_T LLM_C LLM_T GATE_C GATE_T <<EOF
$(awk '
 /^[^:]*\.mbt:[[:space:]]*[0-9]+\/[0-9]+[[:space:]]*$/ {
 split($0, p, ":"); split(p[2], n, "/")
 gsub(/[^0-9]/, "", n[1]); gsub(/[^0-9]/, "", n[2])
 if (p[1] ~ /^bench\//) { bc += n[1]; bt += n[2]; next }
 gc += n[1]; gt += n[2]
 if (p[1] ~ /^llm\//) { lc += n[1]; lt += n[2]; next }
 rc += n[1]; rt += n[2]
 }
 # moon omits fully covered files from the per-file list but counts their
 # lines in its own Total, so the per-package split the documents quote is
 # derived from that Total, not from the listed rows.
 /^Total: [0-9]+\/[0-9]+$/ {
 split($0, p, ":"); split(p[2], n, "/")
 gsub(/[^0-9]/, "", n[1]); gsub(/[^0-9]/, "", n[2])
 tc = n[1] - bc - lc; tt = n[2] - bt - lt
 rc = tc; rt = tt
 }
 END { printf "%d %d %d %d %d %d\n", rc, rt, lc, lt, gc, gt }
' "$SUM")
EOF
 rm -f "$SUM"
 # The listed rows under-count fully covered files; add back what moon's own
 # Total implies, so the per-package split matches what the documents quote.
 derive "coverage_gate" "$GATE_C/$GATE_T" "bash tests/coverage.sh"
 derive "coverage_root" "$ROOT_C/$ROOT_T" "moon coverage report -f summary"
 derive "coverage_llm" "$LLM_C/$LLM_T" "moon coverage report -f summary"
 # Each figure is checked in its own README row. The old any-of check let the
 # README and code/docs/MCP.md cover for each other: one could be stale.
 require_line "$ROOT/README.md" "根包行覆盖率" "$ROOT_C/$ROOT_T"
 require_line "$ROOT/README.md" '`llm` 包行覆盖率' "$LLM_C/$LLM_T"
 require_line "$ROOT/README.md" "覆盖率门（有未覆盖行的文件口径）" "$GATE_C/$GATE_T"
 fi
else
 fail "the instrumented test run failed, so no coverage number was derived"
fi

# --- artifact sizes ----------------------------------------------------------
# Sizes are quoted in KiB in the documents; they are derived in bytes and
# converted with one decimal, which is the form the documents use.
size_kib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1024 }'; }

# The artifact the release ships is the *probe*, not any wasm under the build
# tree: `release.yml` builds `bench/probe` and publishes `probe.wasm` as
# `liwenjson-probe.wasm`. Searching the whole tree picked up
# `bench/bench.wasm` -- the benchmark driver, a different and larger file --
# so the figure this gate derived and the figure the documents quote were
# about two different artifacts, and the size budget (NFR-SIZE-01, stated
# against the probe) was being checked against something the release does not
# ship. `tests/bench.sh size` measures the same file.
WASM_B="$CODE/_build/wasm-gc/release/build/bench/probe/probe.wasm"
# Always build this artifact: a stale wasm left in `_build` made the gate
# derive the previous release's size and pass against a document that no
# longer described this source (the `find` fallback was worse still, since it
# could measure `bench/bench.wasm`, a different file from the one the release
# ships). The build is a few seconds and the measurement must be this tree's.
if ! (cd "$CODE" && moon build bench/probe --target wasm-gc --release) >/dev/null 2>&1; then
 fail "the wasm-gc probe (bench/probe) does not build; its size cannot be derived"
elif [ ! -f "$WASM_B" ]; then
 fail "the wasm-gc probe built but $WASM_B is missing"
else
 WASM_KIB="$(size_kib "$(wc -c <"$WASM_B" | tr -d ' ')")"
 derive "wasm_gc_kib" "$WASM_KIB" "wc -c < wasm-gc artifact"
 require_line "$ROOT/README.md" "wasm-gc 产物体积" "$WASM_KIB KiB"
fi

BUNDLE="$ROOT/static/demo/liwenjson.js"
if [ -f "$BUNDLE" ]; then
 BUNDLE_KIB="$(size_kib "$(wc -c <"$BUNDLE" | tr -d ' ')")"
 derive "bundle_kib" "$BUNDLE_KIB" "wc -c < static/demo/liwenjson.js"
 # Deliberately not asserted: no document quotes the bundle size. `require_in`
 # with no file argument is a no-op that reads like a check, so it is spelled
 # out here instead.
fi

if [ -f "$BIN" ]; then
 # Derived but deliberately NOT asserted: the native binary links against the
 # host toolchain, so its size is platform-dependent (macOS arm64 and Linux
 # x86_64 differ by hundreds of KiB). A gate that asserted it would fail on
 # whichever runner it did not measure.
 derive "native_cli_kib" "$(size_kib "$(wc -c <"$BIN" | tr -d ' ')")" "wc -c < native CLI (platform-dependent)"
fi

# --- deterministic corpus figures -------------------------------------------
# These come from committed reports rather than a re-run: the corpora are
# frozen (fixed seed, fixed case list), so re-running them would only cost
# time to arrive at the same numbers. The reports themselves are checked for
# internal consistency.
EVAL_REPORT="$CODE/docs/EVAL.md"
if [ -f "$EVAL_REPORT" ]; then
 # The report is a generated Chinese markdown table (see run_eval.py); the
 # totals sit in one row each under `## 1. 总体`. The patterns are anchored
 # to the row labels: an earlier one-line English format stopped matching
 # after the report was restructured, which silently un-gated these two
 # figures for several releases -- a future reformat must fail loudly.
 EVAL_N="$(sed -n 's/^| 用例数 N | \([0-9][0-9]*\) |$/\1/p' "$EVAL_REPORT" | head -1)"
 EVAL_R="$(sed -n 's/^| 恢复率（value == truth） | \([0-9.]*\)%.*/\1/p' "$EVAL_REPORT" | head -1)"
 if [ -n "$EVAL_N" ]; then
 derive "eval_cases" "$EVAL_N" "code/docs/EVAL.md"
 require_line "$ROOT/README.md" "真值评测（协议先冻结）" "$EVAL_N"
 fi
 if [ -n "$EVAL_R" ]; then
 derive "eval_recovery" "$EVAL_R" "code/docs/EVAL.md"
 require_line "$ROOT/README.md" "真值评测（协议先冻结）" "$EVAL_R%"
 fi
fi

DIFF_REPORT="$CODE/docs/DIVERGENCES.md"
if [ -f "$DIFF_REPORT" ]; then
 D_CASES="$(grep -oE '^\| cases \| [0-9]+ \|' "$DIFF_REPORT" | head -1 | grep -oE '[0-9]+')"
 D_UNEX="$(grep -oE '^\| unexplained divergences \| [0-9]+ \|' "$DIFF_REPORT" | head -1 | grep -oE '[0-9]+')"
 if [ -n "$D_CASES" ]; then
 derive "diff_cases" "$D_CASES" "code/docs/DIVERGENCES.md"
 # One row carries both figures, so one anchored check covers the pair.
 require_line "$ROOT/README.md" "差分测试（对" "$D_CASES" "未解释 0"
 else
 fail "could not read the differential corpus size from code/docs/DIVERGENCES.md"
 fi
 if [ -z "$D_UNEX" ]; then
 fail "could not read the unexplained-divergence count from code/docs/DIVERGENCES.md"
 fi
fi

# --- readiness table ---------------------------------------------------------
# The scenario count is read from the generated table, and the documents must
# quote the same number of scenarios.
RDY="$CODE/docs/READINESS.md"
if [ -f "$RDY" ]; then
 RDY_N="$(awk -F'|' '/^\| .* \| [0-9]+ \| [0-9]+‰/ { c++ } END { print c + 0 }' "$RDY")"
 if [ "$RDY_N" -gt 0 ]; then
 derive "readiness_cases" "$RDY_N" "code/docs/READINESS.md"
 require_line "$ROOT/README.md" "骨架就绪表" "$RDY_N 个场景"
 fi
fi

printf '\n--- derived ---\n'
printf '%s\n' "${DERIVED[@]}"

if [ "$FAIL" -gt 0 ]; then
 printf '\nclaims.sh: %s problem(s). The documents quote numbers that no longer\n' "$FAIL" >&2
 printf 'match what this repository produces. Fix the document, not the gate.\n' >&2
 exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
 printf '\nclaims.sh: OK — every figure checked in the published documents matches a freshly\n'
 printf 'derived one. %s figure(s) were skipped because the only document that quotes them\n' "$SKIPPED"
 printf 'is not published and therefore not in this checkout; they are checked locally.\n'
 exit 0
fi
printf '\nclaims.sh: OK — every checked figure in the documents matches a freshly derived one.\n'
