#!/bin/bash
# Build the Nightly channel locally and install it to /Applications/Quill
# Nightly.app for side-by-side testing against Stable. Mirrors Crisp's nightly.sh.
set -euo pipefail
cd "$(dirname "$0")"

QUILL_CHANNEL=nightly QUILL_BUILD="${QUILL_BUILD:-0}" ./build.sh

APP="Quill Nightly.app"
osascript -e 'quit app "Quill Nightly"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
ditto "build/$APP" "/Applications/$APP"
open "/Applications/$APP"
echo "Installed and launched /Applications/$APP"
