#!/bin/bash
# Build the Dev channel and install it to /Applications/Quill Dev.app, running side
# by side with a Stable Quill.app (distinct bundle id, no updater). Mirrors
# Crisp/Porter dev.sh.
set -euo pipefail
cd "$(dirname "$0")"

# Ad-hoc signatures change on every build, so macOS keys the Accessibility (TCC) grant
# to a signature that no longer exists after a rebuild — the dictation hotkey and the
# onboarding "Recheck" button then silently break even though the Settings toggle still
# reads ON. Sign dev builds with a STABLE local self-signed identity so the grant sticks
# across rebuilds. Respect an explicit QUILL_SIGN_IDENTITY; otherwise use the conventional
# local cert when it exists, and tell the user how to create it once if it doesn't.
LOCAL_SIGN_IDENTITY="${QUILL_SIGN_IDENTITY:-Quill Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$LOCAL_SIGN_IDENTITY\""; then
  export QUILL_SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
  echo "Signing dev build with stable identity: $LOCAL_SIGN_IDENTITY (Accessibility grant will persist)"
else
  cat >&2 <<EOF
⚠️  No stable code-signing identity "$LOCAL_SIGN_IDENTITY" found in your keychain.
    Falling back to ad-hoc signing — macOS drops the Accessibility grant on every rebuild,
    so the dictation hotkey and the onboarding "Recheck" button will keep breaking.
    Fix it permanently (one time, no Apple account needed):

        ./Scripts/make-signing-cert.sh

    Then re-run ./dev.sh and grant Accessibility once; it sticks from then on.
EOF
fi

QUILL_CHANNEL=dev ./build.sh

APP="Quill Dev.app"
osascript -e 'quit app "Quill Dev"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
ditto "build/$APP" "/Applications/$APP"
open "/Applications/$APP"
echo "Installed and launched /Applications/$APP"
