#!/bin/sh
# Rebuild the browser demo bundle from the MoonBit source.
#
#   cd code && moon build examples/web --target js --release
#   cp code/_build/js/release/build/examples/web/web.js static/demo/liwenjson.js
#
# The bundle registers `liwenjson.repair`, `liwenjson.report` and
# `liwenjson.snapshot` on `globalThis` through the host hooks in
# `code/examples/web/main.mbt`.
#
# This script only produces the bundle. The figures the page quotes in its
# evidence cards are not derived here: `bash code/tests/claims.sh` measures
# them from the artifacts this tree builds, and
# `python3 code/tests/media/index_console_smoke.py` refuses a page whose
# cards disagree with the README. Measure before quoting: a stale artifact
# once made both the card and the gate agree on the previous release's size.
set -e
cd "$(dirname "$0")/../.."
export PATH="$HOME/.moon/bin:$PATH"
(cd code && moon build examples/web --target js --release)
cp code/_build/js/release/build/examples/web/web.js static/demo/liwenjson.js
echo "wrote static/demo/liwenjson.js"
