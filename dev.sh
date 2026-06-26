#!/bin/bash
# Build the Dev channel and install it to /Applications/Quill Dev.app, running side
# by side with a Stable Quill.app (distinct bundle id, no updater). Mirrors
# Crisp/Porter dev.sh.
set -euo pipefail
cd "$(dirname "$0")"

QUILL_CHANNEL=dev ./build.sh

APP="Quill Dev.app"
osascript -e 'quit app "Quill Dev"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
ditto "build/$APP" "/Applications/$APP"
open "/Applications/$APP"
echo "Installed and launched /Applications/$APP"
