#!/bin/bash
# Channel-aware release build for Quill (this fork's identity; the Xcode target is
# still named VoiceInk internally). Mirrors the Crisp/Porter build.sh interface
# (env: QUILL_CHANNEL / QUILL_VERSION / QUILL_BUILD), adapted to the Xcode project +
# whisper.cpp framework. Produces build/<App>.app with the version, channel,
# bundle identity, and channel-tinted icon stamped in.
#
#   ./build.sh                              # stable, version 0.<commit count>
#   QUILL_CHANNEL=nightly QUILL_BUILD=42 ./build.sh
#   QUILL_CHANNEL=dev ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CHANNEL="${QUILL_CHANNEL:-stable}"
BASE_BUNDLE_ID="com.syntaxlabtechnology.quill"
case "$CHANNEL" in
  stable)  APP_NAME="Quill";          BUNDLE_ID="$BASE_BUNDLE_ID" ;;
  nightly) APP_NAME="Quill Nightly";  BUNDLE_ID="$BASE_BUNDLE_ID.nightly" ;;
  dev)     APP_NAME="Quill Dev";      BUNDLE_ID="$BASE_BUNDLE_ID.dev" ;;
  *) echo "Unknown QUILL_CHANNEL: $CHANNEL (want stable|nightly|dev)"; exit 1 ;;
esac

COMMIT_COUNT="$(git rev-list --count HEAD)"
VERSION="${QUILL_VERSION:-0.$COMMIT_COUNT}"
BUILD_NUMBER="${QUILL_BUILD:-}"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

DERIVED="$PWD/.local-build"
OUT_DIR="$PWD/build"
ICONSET="VoiceInk/Assets.xcassets/AppIcon.appiconset"
PRODUCT="$DERIVED/Build/Products/Debug/VoiceInk.app"   # Xcode target name is VoiceInk
DEST_APP="$OUT_DIR/$APP_NAME.app"

echo "Building Quill [$CHANNEL] $VERSION${BUILD_NUMBER:+ (build $BUILD_NUMBER)}..."

# Build the whisper.xcframework if it isn't cached yet (reuses the Makefile logic).
make setup

# Swap in the channel-tinted icon for this build, then restore the committed
# (stable) icon afterwards so the working tree stays clean. Each channel compiles
# its own tint into the asset catalog — no runtime icon-precedence hacks.
ICON_BACKUP="$(mktemp -d /tmp/quill-icon.XXXXXX)"
cp -R "$ICONSET" "$ICON_BACKUP/appiconset"
restore_icon() { rm -rf "$ICONSET"; mv "$ICON_BACKUP/appiconset" "$ICONSET"; rm -rf "$ICON_BACKUP"; }
trap restore_icon EXIT
./Scripts/gen-icons.sh "$CHANNEL" "$ICONSET"

rm -rf "$DERIVED"
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build

mkdir -p "$OUT_DIR"
rm -rf "$DEST_APP"
ditto "$PRODUCT" "$DEST_APP"

# Stamp identity/version/channel into the copied bundle.
PLIST="$DEST_APP/Contents/Info.plist"
set_key() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_key CFBundleShortVersionString "$VERSION"
set_key CFBundleVersion "${BUILD_NUMBER:-$VERSION}"
set_key CFBundleIdentifier "$BUNDLE_ID"
set_key CFBundleName "$APP_NAME"
set_key CFBundleDisplayName "$APP_NAME"
set_key QuillChannel "$CHANNEL"
[ -n "$BUILD_NUMBER" ] && set_key QuillBuildNumber "$BUILD_NUMBER"
[ "$CHANNEL" != "stable" ] && set_key QuillBuildInfo "$BRANCH@$SHA"

# Re-seal: editing the top-level Info.plist invalidated the signature.
#
# Signing identity: ad-hoc (`-`) by default, which is all CI/a fresh clone needs.
# But ad-hoc signatures are derived from the binary hash, so they change on EVERY
# build — and macOS keys the Accessibility (TCC) grant to the signature, so the
# dictation-hotkey permission silently dies on every local update and has to be
# re-granted by hand.
#
# To make the grant stick across local rebuilds, export QUILL_SIGN_IDENTITY with the
# name of a self-signed code-signing certificate from your login keychain. A stable
# certificate gives the bundle a stable designated requirement, so TCC recognizes
# each new build as the same app and the Accessibility grant persists. Create one
# (no Apple account needed) via Keychain Access → Certificate Assistant → Create a
# Certificate → "Self Signed Root" + "Code Signing", then:
#   QUILL_SIGN_IDENTITY="Quill Local" ./build.sh
SIGN_IDENTITY="${QUILL_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" != "-" ]; then
  # Match the identity name exactly: `find-identity` prints each name wrapped in
  # quotes (e.g. `1) ABC… "Quill Local Signing"`), so grep for the quoted string to
  # avoid a fuzzy substring false-positive. No `-v` — a self-signed cert is a usable
  # signing identity even though it isn't "valid" (trusted) for verification; we only
  # need its private key to sign.
  #
  # Feed the listing via a here-string rather than a pipe: under `set -o pipefail`,
  # `security … | grep -q` can report the whole pipeline as failed when grep exits
  # early (matches) and `security` is killed by SIGPIPE — a false negative that would
  # silently downgrade to ad-hoc signing. A here-string has no upstream process.
  SIGN_IDENTITIES="$(security find-identity -p codesigning)"
  if ! grep -qF "\"$SIGN_IDENTITY\"" <<< "$SIGN_IDENTITIES"; then
    echo "QUILL_SIGN_IDENTITY=\"$SIGN_IDENTITY\" not found in keychain; falling back to ad-hoc." >&2
    SIGN_IDENTITY="-"
  fi
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$DEST_APP"
else
  echo "Signing with stable identity: $SIGN_IDENTITY (Accessibility grant will persist across builds)"
  codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$PWD/VoiceInk/VoiceInk.local.entitlements" "$DEST_APP"
fi
xattr -cr "$DEST_APP"

# Reclaim the derived-data intermediates (several GB) now that the product is
# copied to build/ — packaging (make-dmg.sh) needs disk headroom, and CI runners
# run out of space otherwise (whisper.xcframework + derived data fill the volume).
rm -rf "$DERIVED"

echo "Built: $DEST_APP"
