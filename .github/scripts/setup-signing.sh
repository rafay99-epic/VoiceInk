#!/bin/bash
# Import the stable self-signed code-signing certificate into a throwaway keychain so
# ./build.sh signs this CI build with it (via QUILL_SIGN_IDENTITY). A stable signature
# keeps the macOS Accessibility (TCC) grant alive across updates for everyone who
# installs the released DMG — see Scripts/make-signing-cert.sh and CLAUDE.md.
#
# Reads MACOS_SIGN_CERT_P12 (base64 of the .p12) and MACOS_SIGN_CERT_PASSWORD from the
# environment (wired from repo secrets by the workflow). If the secret is absent the
# build falls back to ad-hoc — releases still ship, they just need a manual
# Accessibility re-grant on update. Mirrors the graceful-skip pattern used for TAP_TOKEN.
set -euo pipefail

if [ -z "${MACOS_SIGN_CERT_P12:-}" ] || [ -z "${MACOS_SIGN_CERT_PASSWORD:-}" ]; then
  echo "::warning::MACOS_SIGN_CERT_P12 or MACOS_SIGN_CERT_PASSWORD not set — building ad-hoc. Released builds will require re-granting Accessibility on each update. Run Scripts/make-signing-cert.sh and add the MACOS_SIGN_CERT_P12 / MACOS_SIGN_CERT_PASSWORD secrets to make the dictation-hotkey permission persist."
  exit 0
fi

KEYCHAIN="$RUNNER_TEMP/quill-signing.keychain-db"
KEYCHAIN_PW="$(openssl rand -base64 24)"
CERT_P12="$RUNNER_TEMP/quill-signing.p12"

security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"   # auto-lock after 6h
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"

echo "$MACOS_SIGN_CERT_P12" | base64 --decode > "$CERT_P12"
security import "$CERT_P12" -k "$KEYCHAIN" -P "${MACOS_SIGN_CERT_PASSWORD:-}" -T /usr/bin/codesign
rm -f "$CERT_P12"

# Allow codesign to use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
# Put our keychain first in the search list so `security find-identity` / codesign
# find it, preserving the existing entries. Build an array so keychain paths that
# contain spaces survive as single arguments (a bare $(...) would word-split them).
existing_keychains=()
while IFS= read -r kc; do
  kc="${kc//\"/}"                       # strip the quotes `security` prints
  kc="${kc#"${kc%%[![:space:]]*}"}"     # trim leading whitespace
  [ -n "$kc" ] && existing_keychains+=("$kc")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${existing_keychains[@]}"

# Discover the identity's name from the cert itself (robust to whatever CN was used).
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
if [ -z "$IDENTITY" ]; then
  echo "::error::Imported certificate but found no code-signing identity in the keychain."
  exit 1
fi

echo "QUILL_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "Configured stable signing identity: $IDENTITY"
