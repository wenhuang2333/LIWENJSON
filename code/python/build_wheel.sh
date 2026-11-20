#!/usr/bin/env bash
# Build the publishable Python distributions: one wheel that carries the
# engine for every platform the release ships, plus the sdist it was built from.
#
#   bash code/python/build_wheel.sh [--from-dir DIR]
#
# Why the wheel carries the binaries
# ----------------------------------
#
# `pip install liwenjson` used to install a client with no engine: the
# package is a thin client for `liwenjson serve`, and the binary came from the
# GitHub release. That is a working install only if the user already knew to
# fetch the binary, so the first thing a pip user saw was
#
#   FileNotFoundError: the liwenjson engine was not found
#
# The npm package does not have this problem because the engine compiles to
# JavaScript and travels inside the tarball. The native binary cannot be
# compiled at install time (there is no MoonBit toolchain on a normal machine),
# so it is placed in the wheel: all four release binaries, selected at runtime
# by `find_binary()`. The wheel is ~3 MB, which is noise next to numpy.
#
# The binaries are taken from the published release rather than from a local
# build, so the wheel and the release carry the same bytes and the release's
# own SHA256SUMS is the check. `--from-dir` takes a directory that already
# holds those assets (CI downloads them there; a local build does the same).
#
# `--from-local PLATFORM` packages the binary this checkout compiled. It must
# name the host platform: a Mach-O arm64 binary copied into the linux-x86_64
# directory installs and then fails to exec, and a checksum only proves the
# copy is intact. The local build therefore produces a single-platform test
# wheel for the host, never a multi-platform release wheel.
#
# Every asset -- local, `--from-dir` or downloaded -- is checked for the
# container format and architecture its platform name claims (ELF/Mach-O/PE),
# and the host-platform binary is started after it is staged. Checksums prove
# integrity, not target compatibility.
#
# Exit codes: 0 the distributions were built, 1 a failure, 2 the check could
# not run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE"
OUT="$ROOT/dist/python"
FROM_DIR=""
LOCAL_PLATFORM=""
PLATFORMS="linux-x86_64 linux-arm64 macos-arm64 windows-x86_64"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-dir)
      [ $# -ge 2 ] || { echo "--from-dir needs a directory" >&2; exit 2; }
      FROM_DIR="$2"
      shift 2
      ;;
    --platforms)
      [ $# -ge 2 ] || { echo "--platforms needs a space-separated list" >&2; exit 2; }
      PLATFORMS="$2"
      shift 2
      ;;
    --out)
      [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }
      OUT="$2"
      shift 2
      ;;
    --from-local)
      [ $# -ge 2 ] || { echo "--from-local needs a platform key" >&2; exit 2; }
      LOCAL_PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

RELEASE_PLATFORMS="linux-x86_64 linux-arm64 macos-arm64 windows-x86_64"
case "$(python3 -c 'import platform,sys; print(sys.platform, platform.machine().lower())')" in
  "darwin arm64" | "darwin aarch64") HOST_KEY="macos-arm64" ;;
  "linux x86_64" | "linux amd64") HOST_KEY="linux-x86_64" ;;
  "linux aarch64" | "linux arm64") HOST_KEY="linux-arm64" ;;
  *) HOST_KEY="" ;;
esac

for platform in $PLATFORMS; do
  case " $RELEASE_PLATFORMS " in
    *" $platform "*) ;;
    *) echo "unknown platform key: $platform (the release carries: $RELEASE_PLATFORMS)" >&2; exit 2 ;;
  esac
done

# `--from-local` can only supply the binary this checkout compiled, which runs
# on this host. Refuse a cross-platform claim before copying anything: the
# failure it replaces (a Mach-O arm64 file installed as linux-x86_64) is
# invisible to a checksum and only shows up later as `Exec format error`.
if [ -n "$LOCAL_PLATFORM" ]; then
  [ -n "$HOST_KEY" ] || {
    echo "--from-local needs a host the release builds for (linux-x86_64, linux-arm64, macos-arm64); this host is not one" >&2
    exit 2
  }
  [ "$LOCAL_PLATFORM" = "$HOST_KEY" ] || {
    echo "--from-local $LOCAL_PLATFORM is not this host ($HOST_KEY): the local binary is $HOST_KEY only." >&2
    echo "Refusing to copy it into another platform's directory; use --from-dir with the release assets for a multi-platform wheel." >&2
    exit 2
  }
  [ "$PLATFORMS" = "$LOCAL_PLATFORM" ] || {
    echo "--from-local supplies only $LOCAL_PLATFORM, so --platforms must be exactly the same key (a single-platform test wheel)." >&2
    echo "For the four-platform release wheel, use --from-dir (or no argument, which downloads the release)." >&2
    exit 2
  }
fi

VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/code/moon.mod")"
[ -n "$VERSION" ] || { echo "could not read the version from code/moon.mod" >&2; exit 2; }

# The four binaries the release publishes. `liwenjson-probe.wasm`,
# `liwenjson-demo.js` and `liwenjson-install.sh` are not part of the wheel: the
# first two are not the CLI, and the installer would be a second copy of a
# download path that the wheel exists to remove.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/liwenjson-wheel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# `shasum` is Perl on Linux and may be absent from a minimal image; the coreutils
# tool is the other spelling of the same check.
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
hash_check() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1"; else shasum -a 256 -c "$1"; fi
}

ASSETS="$WORK/assets"
mkdir -p "$ASSETS"

if [ -n "$LOCAL_PLATFORM" ]; then
  # The gate builds the wheel from the binary this checkout just compiled, so
  # the packaging path (package-data, platform directory, find_binary) is
  # exercised on every commit without depending on a published release. The
  # checksum here only proves the copy is intact; the published release's own
  # SHA256SUMS is what a released wheel is verified against.
  case "$LOCAL_PLATFORM" in
    windows-*) local_name="liwenjson.exe" ;;
    *)         local_name="liwenjson" ;;
  esac
  local_bin="$ROOT/code/_build/native/release/build/cmd/liwenjson/liwenjson.exe"
  [ -f "$local_bin" ] || {
    echo "--from-local needs $local_bin; build it with" >&2
    echo "  moon build cmd/liwenjson --target native --release" >&2
    exit 2
  }
  case "$LOCAL_PLATFORM" in
    windows-*) staged="liwenjson-windows-x86_64.exe" ;;
    *)         staged="liwenjson-$LOCAL_PLATFORM" ;;
  esac
  cp "$local_bin" "$ASSETS/$staged"
  ( cd "$ASSETS" && hash_file "$staged" > SHA256SUMS )
elif [ -n "$FROM_DIR" ]; then
  [ -d "$FROM_DIR" ] || { echo "--from-dir $FROM_DIR is not a directory" >&2; exit 2; }
  cp "$FROM_DIR"/* "$ASSETS"/ 2>/dev/null || true
else
  echo "downloading the $VERSION release assets..."
  # github.com is not reachable from every network; api.github.com is, and the
  # asset endpoint redirects to the same bytes. The release API gives us the
  # asset ids, so the download does not depend on a redirect chain either.
  API="https://api.github.com/repos/wenhuang2333/LIWENJSON/releases/tags/v$VERSION"
  curl -fsSL --max-time 60 "$API" -o "$WORK/release.json" || {
    echo "could not read the v$VERSION release; pass --from-dir with the assets" >&2
    exit 2
  }
  python3 - "$WORK/release.json" <<'PY' > "$WORK/ids.txt"
import json
import sys

release = sys.argv[1]
data = json.load(open(release, encoding="utf-8"))
names = {"SHA256SUMS"}
for platform in ("linux-x86_64", "linux-arm64", "macos-arm64", "windows-x86_64.exe"):
    names.add("liwenjson-" + platform)
for asset in data["assets"]:
    if asset["name"] in names:
        print(asset["id"], asset["name"])
PY
  while read -r id name; do
    [ -n "$id" ] || continue
    curl -fsSL --max-time 180 \
      -H "Accept: application/octet-stream" \
      -o "$ASSETS/$name" \
      "https://api.github.com/repos/wenhuang2333/LIWENJSON/releases/assets/$id"
  done < "$WORK/ids.txt"
fi

# --- every binary must be the one the release published ----------------------
# A wheel that carries a stale or truncated binary is worse than one that
# carries none: `pip install` succeeds and every call fails at the protocol
# layer. The release's own SHA256SUMS is the reference, so nothing is trusted
# that a reader could not verify themselves.
[ -f "$ASSETS/SHA256SUMS" ] || {
  echo "no SHA256SUMS among the assets; cannot verify the binaries" >&2
  exit 2
}
asset_name_for() {
  case "$1" in
    windows-*) printf '%s\n' "liwenjson-windows-x86_64.exe" ;;
    *) printf '%s\n' "liwenjson-$1" ;;
  esac
}

(
  cd "$ASSETS"
  # Only the four binaries are in the wheel; the other three lines of
  # SHA256SUMS name files this script does not need.
  filtered="$(mktemp)"
  for platform in $PLATFORMS; do
    name="$(asset_name_for "$platform")"
    [ -f "$name" ] || {
      echo "missing asset: $ASSETS/$name (the $platform binary is not among the assets)" >&2
      exit 2
    }
    line="$(grep -E "  $name\$" SHA256SUMS || true)"
    [ -n "$line" ] || {
      echo "SHA256SUMS does not name $name; refusing to package an unverified binary" >&2
      exit 2
    }
    printf '%s\n' "$line" >> "$filtered"
  done
  hash_check "$filtered"
  rm -f "$filtered"
)

# --- every binary must be the container/architecture its name claims ---------
# A checksum proves the copy, not the target: the P2-06 audit built a wheel
# with a Mach-O arm64 binary in `bin/linux-x86_64`. The headers are
# unambiguous, so check them here instead of trusting the file name.
echo "checking the binaries' format and architecture..."
python3 - "$ASSETS" $PLATFORMS <<'PY'
import sys

assets, platforms = sys.argv[1], sys.argv[2:]
ELF_MACHINE = {"linux-x86_64": 62, "linux-arm64": 183}
MACHO_CPU = {"macos-arm64": 0x0100000C}
PE_MACHINE = {"windows-x86_64": 0x8664}


def name_for(platform):
    return "liwenjson-windows-x86_64.exe" if platform == "windows-x86_64" else "liwenjson-" + platform


def fail(message):
    print("build_wheel.sh: " + message, file=sys.stderr)
    raise SystemExit(1)


def check(path, platform):
    data = open(path, "rb").read(8192)
    if not data:
        fail(f"{path} is empty")
    if platform in ELF_MACHINE:
        if data[:4] != b"\x7fELF":
            fail(f"{path} is not an ELF binary (magic {data[:4]!r}), but the platform is {platform}")
        if data[4] != 2:
            fail(f"{path} is not a 64-bit ELF (EI_CLASS {data[4]})")
        machine = int.from_bytes(data[18:20], "little")
        if machine != ELF_MACHINE[platform]:
            fail(f"{path} is ELF machine {machine:#x}, not {ELF_MACHINE[platform]:#x} ({platform})")
    elif platform in MACHO_CPU:
        magic = int.from_bytes(data[:4], "little")
        if magic == 0xFEEDFACF:  # 64-bit little-endian Mach-O
            cputype = int.from_bytes(data[4:8], "little")
        elif int.from_bytes(data[:4], "big") == 0xCAFEBABE:  # universal binary
            cputype = int.from_bytes(data[8:12], "big")
        else:
            fail(f"{path} is not a Mach-O binary (magic {data[:4]!r}), but the platform is {platform}")
        if cputype != MACHO_CPU[platform]:
            fail(f"{path} is Mach-O cputype {cputype:#x}, not {MACHO_CPU[platform]:#x} ({platform})")
    elif platform in PE_MACHINE:
        if data[:2] != b"MZ":
            fail(f"{path} is not a PE binary (no MZ header), but the platform is {platform}")
        e_lfanew = int.from_bytes(data[0x3C:0x40], "little")
        if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
            fail(f"{path} has no PE signature at {e_lfanew:#x}")
        machine = int.from_bytes(data[e_lfanew + 4:e_lfanew + 6], "little")
        if machine != PE_MACHINE[platform]:
            fail(f"{path} is PE machine {machine:#x}, not {PE_MACHINE[platform]:#x} ({platform})")
    else:
        fail(f"no format rule for platform {platform}")


for platform in platforms:
    check(assets + "/" + name_for(platform), platform)
PY

# --- assemble the package tree ----------------------------------------------
mkdir -p "$WORK/tree"
cp -R "$HERE/liwenjson" "$WORK/tree/liwenjson"
cp "$HERE/README.md" "$HERE/LICENSE" "$HERE/NOTICE" "$WORK/tree/"
cp "$HERE/pyproject.toml" "$WORK/tree/"

# Strip bytecode and build leftovers, then place one directory per platform so
# `find_binary()` can pick the one this interpreter can actually run.
find "$WORK/tree" -name '__pycache__' -type d -prune -exec rm -rf {} +
rm -rf "$WORK/tree/liwenjson/bin"
for platform in $PLATFORMS; do
  case "$platform" in
    windows-*) name="liwenjson-windows-x86_64.exe" ;;
    *) name="liwenjson-$platform" ;;
  esac
  mkdir -p "$WORK/tree/liwenjson/bin/$platform"
  case "$platform" in
    windows-*) cp "$ASSETS/$name" "$WORK/tree/liwenjson/bin/$platform/liwenjson.exe" ;;
    *)         cp "$ASSETS/$name" "$WORK/tree/liwenjson/bin/$platform/liwenjson" ;;
  esac
  chmod +x "$WORK/tree/liwenjson/bin/$platform"/*
done

# --- the host binary must actually start before it is packaged ---------------
# The last step a checksum cannot do. It is only meaningful for the platform
# this script runs on; the other three are validated structurally above and run
# on their own target by the release jobs.
if [ -n "$HOST_KEY" ]; then
  case " $PLATFORMS " in
    *" $HOST_KEY "*)
      host_bin="$WORK/tree/liwenjson/bin/$HOST_KEY/liwenjson"
      case "$HOST_KEY" in windows-*) host_bin="$host_bin.exe" ;; esac
      if ! "$host_bin" --version >"$WORK/host-version.txt" 2>&1; then
        echo "build_wheel.sh: the staged $HOST_KEY binary did not start:" >&2
        cat "$WORK/host-version.txt" >&2
        exit 1
      fi
      echo "started : $(cat "$WORK/host-version.txt")"
      ;;
  esac
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.whl "$OUT"/*.tar.gz

# `python -m build` is the normal entry point, but it is not installed
# everywhere and it may not be installable on an offline machine. What it does
# for a setuptools project is `pip wheel` plus `setup.py sdist`, and both of
# those only need setuptools, which is already a build requirement of this
# package. The fallback is what CI runs.
# Both fallbacks are setuptools projects; name the missing piece instead of
# letting pip print "Cannot import build backend 'setuptools.build_meta'".
if ! python3 -c 'import build' 2>/dev/null && ! python3 -c 'import setuptools' 2>/dev/null; then
  echo "build_wheel.sh: no build backend: install 'setuptools' (pip install setuptools) or 'build'" >&2
  exit 1
fi

echo "building the distributions..."
if python3 -c 'import build' 2>/dev/null; then
  python3 -m build --no-isolation --wheel --sdist -o "$OUT" "$WORK/tree" >/dev/null
else
  python3 -m pip wheel --no-deps --no-build-isolation -w "$OUT" "$WORK/tree" >/dev/null
  ( cd "$WORK/tree" && python3 -c 'from setuptools import setup; setup()' sdist --dist-dir "$OUT" >/dev/null )
fi

WHEEL="$(ls "$OUT"/liwenjson-"$VERSION"-*.whl 2>/dev/null | head -1)"
[ -n "$WHEEL" ] || { echo "no wheel was produced" >&2; exit 1; }

# --- the built artefact must carry what the install needs --------------------
python3 - "$WHEEL" "$PLATFORMS" "$VERSION" <<'PY'
import sys
import zipfile

wheel, platforms, version = sys.argv[1], sys.argv[2].split(), sys.argv[3]
names = zipfile.ZipFile(wheel).namelist()
fails = []
for platform in platforms:
    entry = f"liwenjson/bin/{platform}/liwenjson"
    # Windows binaries keep their .exe suffix; everything else is `liwenjson`.
    if entry not in names and f"{entry}.exe" not in names:
        fails.append(f"wheel does not carry {entry}")
for want in ("liwenjson/py.typed", "liwenjson/client.py", "liwenjson/mcp.py"):
    if want not in names:
        fails.append(f"wheel does not carry {want}")
if not any(n.endswith("dist-info/licenses/LICENSE") or n.endswith(".data/data/LICENSE") for n in names):
    fails.append("wheel does not carry LICENSE")
if not any(n.endswith("dist-info/licenses/NOTICE") or n.endswith(".data/data/NOTICE") for n in names):
    fails.append("wheel does not carry NOTICE")
meta = [n for n in names if n.endswith("dist-info/METADATA")]
if meta:
    text = zipfile.ZipFile(wheel).read(meta[0]).decode()
    if f"Version: {version}" not in text:
        fails.append(f"wheel metadata does not say Version: {version}")
else:
    fails.append("wheel has no METADATA")
if fails:
    print("build_wheel.sh:", file=sys.stderr)
    for f in fails:
        print("  " + f, file=sys.stderr)
    raise SystemExit(1)
PY

echo "built:"
ls -1 "$OUT" | sed 's/^/  /'
