#!/bin/bash
# Package the channel's build/<App>.app into build/<DMG> — a drag-to-Applications
# installer. Mirrors Porter's make-dmg.sh (plain hdiutil, no create-dmg dep). Run
# ./build.sh first.
set -euo pipefail
cd "$(dirname "$0")"

CHANNEL="${QUILL_CHANNEL:-stable}"
case "$CHANNEL" in
  stable)  APP_NAME="Quill";         DMG_NAME="Quill.dmg" ;;
  nightly) APP_NAME="Quill Nightly"; DMG_NAME="Quill-Nightly.dmg" ;;
  dev)     echo "Dev channel doesn't publish a DMG."; exit 1 ;;
  *) echo "Unknown QUILL_CHANNEL: $CHANNEL"; exit 1 ;;
esac

OUT_DIR="$PWD/build"
APP="$OUT_DIR/$APP_NAME.app"
DMG="$OUT_DIR/$DMG_NAME"
[ -d "$APP" ] || { echo "Missing $APP — run ./build.sh first."; exit 1; }

STAGING="$(mktemp -d /tmp/quill-dmg.XXXXXX)"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "DMG: $DMG"
