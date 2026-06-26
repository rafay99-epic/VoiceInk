#!/bin/bash
# Generate a self-signed code-signing certificate for Quill — no Apple account.
#
# Why: Quill is ad-hoc signed, and an ad-hoc signature changes on every build. macOS
# keys the Accessibility (TCC) grant to the signature, so the dictation-hotkey
# permission silently dies on every update. A STABLE certificate gives every build
# the same designated requirement, so the grant persists across updates.
#
# This script:
#   1. creates a self-signed code-signing cert + key,
#   2. imports it into your login keychain (so local `QUILL_SIGN_IDENTITY=... ./build.sh` works),
#   3. exports a password-protected .p12 and prints it base64-encoded for the CI secret.
#
# Run it in YOUR terminal (it will prompt for your login-keychain password):
#   ./Scripts/make-signing-cert.sh
#
# Then for GitHub Actions, add the printed values as repo secrets:
#   MACOS_SIGN_CERT_P12       = (the base64 blob)
#   MACOS_SIGN_CERT_PASSWORD  = (the p12 password you choose below)
set -euo pipefail

IDENTITY_NAME="${QUILL_SIGN_IDENTITY:-Quill Local Signing}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEY="$WORK/key.pem"
CERT="$WORK/cert.pem"
P12="$WORK/quill-signing.p12"

read -r -s -p "Choose a password for the exported .p12 (used as the CI secret): " P12_PW
echo
[ -n "$P12_PW" ] || { echo "Password cannot be empty." >&2; exit 1; }

echo "Generating self-signed code-signing certificate \"$IDENTITY_NAME\"..."
openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -days 3650 -nodes \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Legacy PBE (SHA1/3DES + SHA1 MAC): OpenSSL 3's default PKCS#12 encryption
# (AES-256/SHA-256) cannot be read by macOS's `security import` ("MAC verification
# failed"), which is what CI uses. These flags keep the .p12 importable everywhere.
openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -out "$P12" \
  -name "$IDENTITY_NAME" -passout pass:"$P12_PW" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
echo "Importing into your login keychain (may prompt for your keychain password)..."
security import "$P12" -k "$LOGIN_KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign
# Trust the cert for code signing in the login keychain so codesign uses it cleanly.
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERT" 2>/dev/null || \
  echo "Note: could not auto-add trust; signing still works, but you may get a one-time keychain prompt on first sign."

echo
echo "Done. Local builds:  QUILL_SIGN_IDENTITY=\"$IDENTITY_NAME\" ./build.sh"
echo
echo "===== GitHub Actions secrets ====="
echo "MACOS_SIGN_CERT_PASSWORD = (the password you just chose)"
echo "MACOS_SIGN_CERT_P12      = (base64 below, single line)"
echo "-----------------------------------"
base64 < "$P12"
echo "-----------------------------------"
echo "Add them with:  gh secret set MACOS_SIGN_CERT_P12 < <(base64 -i path/to.p12)"
echo "            and: gh secret set MACOS_SIGN_CERT_PASSWORD"
