#!/usr/bin/env bash
# Gate: the release asset set, the workflow that publishes it and the installer
# that consumes it must agree.
#
# C-09 / §9.6 (marks/1120优化.md): the release ships seven assets plus
# SHA256SUMS, and until now each of the three places that name them -- the
# `want="..."` line in `.github/workflows/release.yml`, the `dist/` directory
# the publish job packages, and the platform table in `code/install.sh` -- was
# checked only against itself. A platform the toolchain cannot build, or an
# asset the installer would download but the release does not carry, could land
# in a release and no step would notice.
#
# What is checked here:
#   1. `release.yml` declares the release contents in one `want=` line, and that
#      declaration is exactly the seven assets plus SHA256SUMS.
#   2. The toolchain is pinned in every workflow that installs it (`C-06`): a
#      `latest` install changes the JavaScript backend's output overnight and
#      turns unrelated commits red.
#   3. `release.yml` verifies the published assets with per-file hashes
#      (`--verify-hashes`), not only the set of names.
#   4. `code/install.sh` maps every supported (os, arch) to an asset that is
#      actually released, and refuses the platforms it cannot support instead of
#      guessing a 404.
#   5. With `--dist <dir>`, the packaged directory is that asset set.
#
# The installer is exercised, not grepped: a fake `uname` picks the platform,
# a fake `curl` records the URL the script would download and fails, and the
# exit code / URL / rejection are asserted. That way a refactor of install.sh
# cannot quietly change its behaviour without this gate noticing.
#
# Exit codes: 0 all agree, 1 disagreement, 2 cannot run (missing file/tool).
#
#   bash code/tests/release_manifest_check.sh
#   bash code/tests/release_manifest_check.sh --dist dist
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_YML="$ROOT/.github/workflows/release.yml"
CI_YML="$ROOT/.github/workflows/ci.yml"
INSTALLER="$ROOT/code/install.sh"
DIST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dist) DIST="${2:-}"; shift 2 ;;
    --release-yml) RELEASE_YML="${2:-}"; shift 2 ;;
    --installer) INSTALLER="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'release_manifest_check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

FAIL=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

for f in "$RELEASE_YML" "$CI_YML" "$INSTALLER"; do
  [ -f "$f" ] || { printf 'release_manifest_check: cannot run -- %s is missing\n' "$f" >&2; exit 2; }
done

# Sha-named files the release carries: exactly what README.md documents and
# `release.yml`'s publish step packages.
EXPECTED=(
  SHA256SUMS
  liwenjson-demo.js
  liwenjson-install.sh
  liwenjson-linux-arm64
  liwenjson-linux-x86_64
  liwenjson-macos-arm64
  liwenjson-probe.wasm
  liwenjson-windows-x86_64.exe
)

sorted_list() { printf '%s\n' "$@" | LC_ALL=C sort; }

# --- 1. the declared release contents ----------------------------------------
want_line="$(grep -nE '^[[:space:]]*want="' "$RELEASE_YML" | head -1)"
if [ -z "$want_line" ]; then
  fail "$RELEASE_YML no longer declares the release contents in a want=\"...\" line"
else
  want="$(printf '%s' "${want_line#*want=\"}" | sed 's/"$//')"
  want_sorted="$(printf '%s\n' $want | LC_ALL=C sort)"
  expected_sorted="$(sorted_list "${EXPECTED[@]}")"
  if [ "$want_sorted" != "$expected_sorted" ]; then
    missing="$(comm -23 <(printf '%s\n' "$expected_sorted") <(printf '%s\n' "$want_sorted") | tr '\n' ' ')"
    extra="$(comm -13 <(printf '%s\n' "$expected_sorted") <(printf '%s\n' "$want_sorted") | tr '\n' ' ')"
    fail "release.yml want= does not match the seven assets + SHA256SUMS (missing: ${missing:-none}; extra: ${extra:-none})"
  fi
fi

# --- 2. the toolchain is pinned everywhere it is installed -------------------
pin_count() { grep -cE '^[[:space:]]*MOONBIT_INSTALL_VERSION:' "$1" || true; }
installer_count() {
  grep -cE 'install/(unix\.sh|powershell\.ps1) \| (bash|iex)' "$1" || true
}
for wf in "$CI_YML" "$RELEASE_YML"; do
  pins="$(pin_count "$wf")"
  installs="$(installer_count "$wf")"
  if [ "$installs" -gt 0 ] && [ "$pins" -lt "$installs" ]; then
    fail "$wf installs the toolchain $installs time(s) but pins MOONBIT_INSTALL_VERSION only $pins time(s)"
  fi
  if ! grep -q "MOONBIT_INSTALL_VERSION: \${{ vars.MOONBIT_VERSION || '0.10.16+b1a0e846e' }}" "$wf"; then
    fail "$wf does not pin the toolchain to 0.10.16+b1a0e846e (allow the MOONBIT_VERSION override)"
  fi
done

# --- 3. the published assets are hash-verified -------------------------------
if ! grep -A8 'release_assets\.sh' "$RELEASE_YML" | grep -q -- '--verify-hashes'; then
  fail "$RELEASE_YML does not pass --verify-hashes to release_assets.sh; a set-of-names check cannot prove the files are the ones SHA256SUMS describes"
fi

# --- 4. the installer's platform table ---------------------------------------
# A fake platform plus a fake `curl` that records what the script would fetch.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release_manifest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/dest"

cat >"$WORK/bin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -s) printf '%s\n' "${FAKE_UNAME_S:?}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:?}" ;;
  *) printf '%s\n' "${FAKE_UNAME_S:?}" ;;
esac
SH
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
# Record the URL and fail: the gate only needs to know what install.sh would
# download, not to install anything.
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
exit 1
SH
chmod +x "$WORK/bin/uname" "$WORK/bin/curl"

check_platform() {
  local label="$1" os_name="$2" arch="$3" want_rc="$4" want_asset="$5"
  local log="$WORK/curl.log"
  rm -f "$log"
  local rc=0
  env PATH="$WORK/bin:$PATH" \
    FAKE_UNAME_S="$os_name" FAKE_UNAME_M="$arch" FAKE_CURL_LOG="$log" \
    LIWENJSON_VERSION="v0.0.0-gate" LIWENJSON_DIR="$WORK/dest" \
    bash "$INSTALLER" >"$WORK/installer.out" 2>&1 || rc=$?
  case "$want_rc" in
  2)
    if [ "$rc" -ne 2 ]; then
      fail "install.sh must refuse $label (exit 2), it exited $rc"
    fi
    if [ -s "$log" ]; then
      fail "install.sh must refuse $label before downloading anything, it requested: $(head -1 "$log")"
    fi
    ;;
  1)
    if [ "$rc" -eq 2 ]; then
      fail "install.sh refuses $label, but the toolchain releases an asset for it"
      return 0
    fi
    local asset
    asset="$(grep -oE 'liwenjson-[A-Za-z0-9._-]+\.(exe|wasm|js|sh)|liwenjson-(linux|macos|windows)-[A-Za-z0-9._-]+' "$log" 2>/dev/null | head -1)"
    if [ -z "$asset" ]; then
      fail "install.sh on $label did not request an asset: $(head -3 "$WORK/installer.out")"
      return 0
    fi
    if [ "$asset" != "$want_asset" ]; then
      fail "install.sh on $label would download '$asset', expected '$want_asset'"
    fi
    if ! printf '%s\n' "${EXPECTED[@]}" | grep -qxF -- "$asset"; then
      fail "install.sh on $label would download '$asset', which the release does not carry (the request would 404)"
    fi
    ;;
  esac
}

# The platform matrix is whatever the MoonBit toolchain publishes:
# darwin-aarch64, linux-x86_64, linux-aarch64, windows-x86_64.
check_platform "Linux x86_64" Linux x86_64 1 liwenjson-linux-x86_64
check_platform "Linux aarch64" Linux aarch64 1 liwenjson-linux-arm64
check_platform "Linux arm64" Linux arm64 1 liwenjson-linux-arm64
check_platform "macOS arm64" Darwin arm64 1 liwenjson-macos-arm64
check_platform "Windows x86_64" MINGW64_NT-10.0 x86_64 1 liwenjson-windows-x86_64.exe
# Platforms with no asset must be refused explicitly, not guessed at: a request
# for `liwenjson-windows-arm64.exe` is a 404 dressed up as a platform.
check_platform "macOS x86_64 (Intel, no toolchain)" Darwin x86_64 2 ""
check_platform "Windows arm64 (no asset)" MINGW64_NT-10.0 arm64 2 ""
check_platform "FreeBSD" FreeBSD amd64 2 ""

# --- 5. the packaged directory, when the caller has one ----------------------
if [ -n "$DIST" ]; then
  if [ ! -d "$DIST" ]; then
    printf 'release_manifest_check: cannot run -- %s is not a directory\n' "$DIST" >&2
    exit 2
  fi
  actual="$(cd "$DIST" && ls -1 | LC_ALL=C sort)"
  expected_sorted="$(sorted_list "${EXPECTED[@]}")"
  if [ "$actual" != "$expected_sorted" ]; then
    fail "$DIST does not hold exactly the release set (actual: $(printf '%s ' $actual))"
  fi
fi

if [ "$FAIL" -gt 0 ]; then
  printf 'release_manifest_check: %s problem(s). The release set, the workflow and the installer disagree.\n' "$FAIL" >&2
  exit 1
fi
printf 'release_manifest_check: OK — %s assets, every installer platform maps to one, unsupported platforms are refused explicitly.\n' "${#EXPECTED[@]}"
