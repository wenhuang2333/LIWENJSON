#!/bin/sh
# Rebuild the browser demo bundle from the MoonBit source.
#
#   cd code && moon build examples/web --target js --release
#   cp code/_build/js/release/build/examples/web/web.js static/demo/liwenjson.js
#
# The bundle registers `liwenjson.repair`, `liwenjson.report` and
# `liwenjson.snapshot` on `globalThis` through the host hooks in
# `code/examples/web/main.mbt`.
set -e
cd "$(dirname "$0")/../.."
export PATH="$HOME/.moon/bin:$PATH"
(cd code && moon build examples/web --target js --release)
cp code/_build/js/release/build/examples/web/web.js static/demo/liwenjson.js
echo "wrote static/demo/liwenjson.js"
