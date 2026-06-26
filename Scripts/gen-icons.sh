#!/bin/bash
# Generate the channel-tinted app icon into an .appiconset. Renders a 1024 master
# via Scripts/MakeIcon.swift, then downsamples to every required size with sips.
# Channel colors mirror the Crisp/Porter convention: stable=blue, nightly=amber,
# dev=purple.
#   Scripts/gen-icons.sh <stable|nightly|dev> [appiconset-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${1:-stable}"
ICONSET="${2:-VoiceInk/Assets.xcassets/AppIcon.appiconset}"
case "$CHANNEL" in
  stable)  TOP="4F9CF9"; BOT="2563EB" ;;  # blue
  nightly) TOP="FBBF24"; BOT="D97706" ;;  # amber
  dev)     TOP="C084FC"; BOT="7C3AED" ;;  # purple
  *) echo "unknown channel: $CHANNEL"; exit 1 ;;
esac

MASTER="$(mktemp /tmp/quill-icon-XXXXXX).png"
swift Scripts/MakeIcon.swift "$TOP" "$BOT" "$MASTER"
for sz in 16 32 64 128 256 512 1024; do
  sips -z "$sz" "$sz" "$MASTER" --out "$ICONSET/${sz}-mac.png" >/dev/null
done
rm -f "$MASTER"
echo "icons ($CHANNEL) → $ICONSET"
