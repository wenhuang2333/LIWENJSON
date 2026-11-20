#!/bin/sh
# Install the LIWENJSON CLI (and its local MCP server) from a GitHub release.
#
#   curl -fsSL https://github.com/wenhuang2333/LIWENJSON/releases/latest/download/liwenjson-install.sh | sh
#   sh liwenjson-install.sh --dry-run
#
# The script does four things and nothing else:
#
#   1. works out which platform it is running on,
#   2. downloads the matching release asset,
#   3. verifies its SHA-256 against the release's own SHA256SUMS,
#   4. puts the binary somewhere on PATH and says which directory that was.
#
# It never installs anything else, never writes outside the install directory
# and the PATH hint file, and never runs the binary as root. A checksum that
# does not match is a hard failure: the file is deleted and nothing is
# installed.
#
# The platform table is the release's asset set, no more and no less. The
# MoonBit toolchain publishes `darwin-aarch64`, `linux-x86_64`, `linux-aarch64`
# and `windows-x86_64`, so there is no Intel macOS build and no arm64 Windows
# build. Those combinations are refused with exit 2 *before* anything is
# downloaded; the script does not guess that x64 emulation will work.
#
# Environment:
#   LIWENJSON_VERSION   release tag to install (default: the latest release)
#   LIWENJSON_DIR       install directory (default: $HOME/.local/bin)
#   LIWENJSON_REPO      owner/name (default: wenhuang2333/LIWENJSON)
#   LIWENJSON_DRY_RUN   `1` prints the resolved platform/asset and stops
#                       before downloading (same as `--dry-run`)
#
# Arguments:
#   --dry-run   resolve the platform and asset, print them, download nothing
#   -h, --help  print this header
#
# Exit codes:
#   0  installed (or, with --dry-run, the platform is supported and resolved)
#   1  the download, the checksum or the install failed
#   2  the platform is not supported by this release, or the usage is wrong

set -eu

REPO="${LIWENJSON_REPO:-wenhuang2333/LIWENJSON}"
VERSION="${LIWENJSON_VERSION:-}"
INSTALL_DIR="${LIWENJSON_DIR:-$HOME/.local/bin}"
DRY_RUN="${LIWENJSON_DRY_RUN:-0}"

# `die` takes the exit code it should end with, because the header documents
# three of them: 1 for a failed download/log/checksum/install, 2 for an
# unsupported platform or bad usage. A single exit code made the documented
# contract a lie -- a script that always exits 1 cannot be branched on.
die() {
  code="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die 1 "$1 is required but was not found"
}

usage() {
  # The header is the help text. `$0` is `sh` when the script is piped, so
  # fall back to the inline summary then.
  if [ -f "$0" ] && sed -n '2,40p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; then
    return 0
  fi
  printf '%s\n' \
    'usage: liwenjson-install.sh [--dry-run]' \
    '' \
    'Installs the LIWENJSON CLI from the latest GitHub release.' \
    '  LIWENJSON_VERSION  release tag (default: latest)' \
    '  LIWENJSON_DIR      install directory (default: $HOME/.local/bin)' \
    '  LIWENJSON_REPO     owner/name (default: wenhuang2333/LIWENJSON)'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die 2 "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

need uname

# -- platform --------------------------------------------------------------

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux) os_name="linux" ;;
  Darwin) os_name="macos" ;;
  MINGW* | MSYS* | CYGWIN*) os_name="windows" ;;
  *) die 2 "unsupported operating system: $os" ;;
esac

case "$arch" in
  x86_64 | amd64) arch_name="x86_64" ;;
  arm64 | aarch64) arch_name="arm64" ;;
  *) die 2 "unsupported architecture: $arch" ;;
esac

# One row per released platform asset. Adding a platform means adding it to
# the release (`release.yml`'s `want=` and `SHA256SUMS`) first; this table must
# never name an asset the release does not carry.
case "$os_name/$arch_name" in
  linux/x86_64) asset="liwenjson-linux-x86_64" ;;
  linux/arm64) asset="liwenjson-linux-arm64" ;;
  macos/arm64) asset="liwenjson-macos-arm64" ;;
  windows/x86_64) asset="liwenjson-windows-x86_64.exe" ;;
  macos/x86_64)
    # There is no Intel macOS build, and the reason is not a choice: the
    # MoonBit toolchain publishes `darwin-aarch64`, `linux-x86_64` and
    # `linux-aarch64` only, so an Intel Mac cannot build the binary at all.
    die 2 "no LIWENJSON build for Intel macOS: the MoonBit toolchain has no darwin-x86_64 target (build from source on an Apple Silicon Mac, or use a Linux/Windows machine)"
    ;;
  windows/arm64)
    # No `liwenjson-windows-arm64.exe` is released, and assuming that Windows'
    # x64 emulation runs the x86_64 asset is a guess this script must not make
    # (a 404 here would be a platform claim the release cannot back).
    die 2 "no LIWENJSON build for Windows arm64: the release carries liwenjson-windows-x86_64.exe only; use an x86_64 Windows machine or build from source"
    ;;
  *) die 2 "unsupported platform: $os/$arch" ;;
esac

# -- version ---------------------------------------------------------------

if [ -z "$VERSION" ] && [ "$DRY_RUN" = "0" ]; then
  need curl
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)"
  [ -n "$VERSION" ] || die 1 "could not determine the latest release; set LIWENJSON_VERSION"
fi

if [ -z "$VERSION" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
  shown_version="(latest)"
else
  base="https://github.com/${REPO}/releases/download/${VERSION}"
  shown_version="$VERSION"
fi

printf 'LIWENJSON %s\n' "$shown_version"
printf '  platform : %s/%s (%s)\n' "$os_name" "$arch_name" "$asset"
printf '  target   : %s\n' "$INSTALL_DIR"

if [ "$DRY_RUN" = "1" ]; then
  # No download, no write: the self-check prints what it would do and stops.
  printf '  dry-run  : would download %s/%s\n' "$base" "$asset"
  exit 0
fi

# -- download --------------------------------------------------------------

tmp="$(mktemp -d)" || die 1 "could not create a temporary directory"
trap 'rm -rf "$tmp"' EXIT INT TERM

printf '  download : '
curl -fsSL -o "$tmp/$asset" "${base}/${asset}" || die 1 "download failed: ${base}/${asset}"
[ -s "$tmp/$asset" ] || die 1 "downloaded $asset is empty"
printf 'ok\n'

printf '  checksums: '
curl -fsSL -o "$tmp/SHA256SUMS" "${base}/SHA256SUMS" || die 1 "SHA256SUMS could not be downloaded"
printf 'ok\n'

# -- verify ----------------------------------------------------------------

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)"
else
  die 1 "neither sha256sum nor shasum is available; cannot verify the download"
fi

expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1 }' "$tmp/SHA256SUMS" | head -n 1)"
[ -n "$expected" ] || die 1 "SHA256SUMS does not name $asset; refusing to install an unverified binary"

if [ "$actual" != "$expected" ]; then
  rm -f "$tmp/$asset"
  die 1 "checksum mismatch for $asset (expected $expected, got $actual); nothing was installed"
fi
printf '  verified : sha256 %s\n' "$actual"

# -- install ---------------------------------------------------------------

mkdir -p "$INSTALL_DIR" 2>/dev/null || die 1 "could not create the install directory: $INSTALL_DIR"
[ -d "$INSTALL_DIR" ] || die 1 "the install directory is not a directory: $INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || die 1 "the install directory is not writable: $INSTALL_DIR"

if [ "$os_name" = "windows" ]; then
  target="$INSTALL_DIR/liwenjson.exe"
else
  target="$INSTALL_DIR/liwenjson"
fi

if [ -d "$target" ]; then
  die 1 "cannot install over the directory $target"
fi
if [ -e "$target" ] && [ ! -w "$target" ]; then
  die 1 "cannot replace $target: the existing file is not writable"
fi

cp "$tmp/$asset" "$target" || die 1 "could not copy $asset to $target"
chmod +x "$target" 2>/dev/null || die 1 "could not make $target executable"
[ -x "$target" ] || die 1 "$target is not executable after the install"

printf '  installed: %s\n' "$target"

# -- verify the binary and report -----------------------------------------

if "$target" --version >/dev/null 2>&1; then
  printf '\n%s\n' "$("$target" --version)"
else
  printf '\nwarning: %s did not answer --version; the install may be incomplete\n' "$target" >&2
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf '\n%s is not on your PATH. Add this to your shell profile:\n\n' "$INSTALL_DIR"
    printf '  export PATH="$INSTALL_DIR:$PATH"\n\n'
    ;;
esac

cat <<'EOF'
Next: start the local execution gate for any MCP client.

  liwenjson mcp --print-config=claude     # prints the Claude Code config
  liwenjson mcp --print-config=cursor
  liwenjson mcp --print-config=json       # the raw MCP server config

or run the gate directly:

  echo '{"a":1,}' | liwenjson --check
EOF
