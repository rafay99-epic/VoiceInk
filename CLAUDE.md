# CLAUDE.md — Quill (a VoiceInk fork)

Quill is a native macOS **menu-bar dictation app**: hold a hotkey, speak, and the
transcript is pasted into the focused app. Speech-to-text runs **100% locally** via
**whisper.cpp** (Metal-accelerated); the optional cleanup pass can run against a
local LLM (Ollama) or a cloud provider. This is a personal fork of
[`Beingpax/VoiceInk`](https://github.com/Beingpax/VoiceInk) (GPL-3.0), **rebranded to
Quill** with its own name, bundle id, and icon so it has a distinct identity rather
than impersonating the upstream paid app. The single reason this fork exists is
documented below — read it before touching licensing.

**Naming note (important):** the product **and the GitHub repo** are **Quill**
(`rafay99-epic/Quill`), but the Xcode *target/scheme* and the source folder are still
named **`VoiceInk`** (`VoiceInk.xcodeproj`, scheme `VoiceInk`, `VoiceInk/` sources).
Renaming those is deep, breakage-prone surgery for no benefit — **leave them**.
`build.sh` builds the `VoiceInk` target and renames/re-stamps the product to
`Quill.app`, exactly how Crisp builds `Crisp.app` from its target. So "VoiceInk" in a
path/target/scheme = correct; "VoiceInk" as the app name or repo = should be "Quill".

## Why this fork exists (the load-bearing context)

Upstream VoiceInk is GPL-3.0 source but the **prebuilt** app is a paid product: a
7-day trial, then a Polar-issued license is required, and once the trial expires the
app **prepends an upgrade nag to every transcription** (see
`TranscriptionDelivery.deliverableText`). GPL-3.0 explicitly grants the right to
modify and run your own build, so this fork **permanently disables the trial and the
license/payment gate** for personal use.

**The entire patch lives in one place: `VoiceInk/Models/LicenseViewModel.swift`.**
It is the single source of truth every other surface reads from — the transcription
gate, the dashboard badge, the onboarding "licensed" check, and License Management
all branch on `licenseState`. Forcing that one value licensed unlocks everything:

- `init()` sets `licenseState = .licensed` **unconditionally** — not behind
  `#if LOCAL_BUILD`, so *every* configuration (Debug, Release, `make local`) ships
  unlocked. The Polar activation paths and 7-day trial are left in place as dead
  code only so the rest of the module compiles unchanged.
- `isLicensed`, `canUseApp` → always `true`. `usageRestrictionMessage` → always
  `nil` (this is what kills the per-transcription paywall nag).
- `setUnlicensedState()` and `refreshTrialState(_:)` are neutered to set
  `.licensed`, so no code path can ever flip the app back to locked/expired.

### Bundle identity (second deviation from upstream)

The app is re-identified as **`com.syntaxlabtechnology.quill`** (was
`com.prakashjoshipax.VoiceInk` upstream) in `VoiceInk.xcodeproj/project.pbxproj`
(main + test targets) and `VoiceInk/VoiceInk.entitlements` (iCloud container +
keychain group); the user-facing name is **Quill** (`CFBundleName`/`DisplayName`,
stamped by `build.sh`). This is **load-bearing, not cosmetic**: macOS TCC keys
Accessibility/Microphone grants to the bundle ID + code signature. Sharing upstream's
ID meant the ad-hoc local build collided with the signed paid app's stale TCC record,
so the Accessibility toggle silently refused to stick. A fresh ID macOS has never
seen registers cleanly. **Keep this ID** on upstream merges. (Per-channel ids:
`…quill` / `…quill.nightly` / `…quill.dev`.)

The ~50 `os.Logger` subsystem strings and `DispatchQueue` labels still read
`com.prakashjoshipax.voiceink` — these are **deliberately left alone**. They are
independent literals (log categories, queue names, the Application Support folder)
that don't affect signing, TCC, or behavior; rewriting them all is a large risky
diff for zero functional gain.

**Do not "clean up" the patch by deleting `PolarService`, `LicenseManager`,
`LicenseView*`, the onboarding license screens, or the unused `trialPeriodDays`.**
They are referenced across the module and by exhaustive `switch`es over the
`LicenseState` enum; removing them is a large, breakage-prone change for zero
functional gain. The point is a *minimal, obvious* diff against upstream — one file,
all in service of "always licensed" — so the next upstream merge is easy to reason
about.

## Workflow rules (explicit — do not violate)

- **No Claude / AI attribution anywhere**: no `Co-Authored-By`, no "Generated with
  Claude" in commits, PR titles/bodies, or changelogs. Credited to
  **Abdul Rafay (rafay99.com)**.
- **`origin` is this fork (`rafay99-epic/Quill`); `upstream` is `Beingpax`.**
  Push only to `origin`. **Never** open a PR or push to `upstream` — the license
  patch must not leak back into the owner's repo.
- **Keep the license patch surgical.** When you sync upstream
  (`git fetch upstream && git merge upstream/main`), the only file expected to
  conflict is `LicenseViewModel.swift`. Re-assert the four "always licensed"
  invariants above and confirm `usageRestrictionMessage` still returns `nil` — that
  is the one that silently re-arms the paywall if a merge reverts it.

## Architecture

This is an **Xcode project** (`VoiceInk.xcodeproj`), not SwiftPM — Swift/SwiftUI app
target plus `VoiceInkTests`/`VoiceInkUITests`. State is `@MainActor` +
`ObservableObject`/`@Published` (older style than the `@Observable` stack in Crisp/
Porter — **don't migrate it**; match what's already in the file you're editing).

Source is organized by concern under `VoiceInk/`:

- `Transcription/` — the engine. `Transcription/Engine/TranscriptionDelivery.swift`
  is where final text is pasted into the focused app (and where the old paywall nag
  was injected).
- `Services/` — UI-free logic: `PolarService` (license HTTP, now dead),
  `LicenseManager` (Keychain-backed license/trial storage), audio, models, updates.
- `Models/` — `LicenseViewModel` (the patch) and other view models.
- `Views/` — SwiftUI. License/trial UI: `LicenseView`, `LicenseManagementView`,
  `Views/Components/TrialMessageView`, `Views/Onboarding/OnboardingLicense*`.
- `Paste/`, `Recorder.swift`, `CoreAudioRecorder.swift` — capture + cursor paste.
- whisper.cpp is **not vendored**; the `Makefile` clones and builds it into a
  framework under `whisper.cpp/` during `make setup`.

**Layer boundary:** Services talk to hardware/subprocesses/HTTP and know nothing
about SwiftUI; Views only display. Keep it that way — e.g. status→color helpers stay
in the View layer.

## Build & run

**Code signing:** ad-hoc only (`codesign --sign -`) — no certificate, no Apple
account, no team. The project's `CODE_SIGN_IDENTITY`/`STYLE` are set to `-`/`Manual`
and `DEVELOPMENT_TEAM` is empty (the upstream dev's team id `V6J6A3VWY2` and the
`Apple Development` identity were removed). Ad-hoc signing **cannot** be dropped
entirely — Apple Silicon refuses to launch an unsigned binary — but it requires
nothing from the developer. Don't re-introduce a real (Apple) identity/team.

**Stable-signature caveat (the Accessibility-grant trap).** An ad-hoc signature is
derived from the binary hash, so it changes on **every build**. macOS keys the
Accessibility/Microphone (TCC) grant to the signature, so each update is seen as a
"new app" and the dictation hotkey silently stops working until the user re-grants
Accessibility (the toggle can still read as ON while being dead). To make the grant
**persist across updates**, builds can be signed with a stable **self-signed**
code-signing certificate — this needs **no Apple account** and is *not* an Apple
identity/team (so it doesn't violate the rule above):

- `build.sh` signs ad-hoc by default; export **`QUILL_SIGN_IDENTITY="<cert name>"`**
  to sign the final bundle with that keychain identity instead. Absent/missing → it
  falls back to ad-hoc, so a fresh clone still builds.
- `Scripts/make-signing-cert.sh` generates the cert, imports it to the login keychain,
  and prints a base64 `.p12` for CI. Run it once locally.
- **CI** (`ci.yml` package+release, `nightly.yml` release) calls
  `.github/scripts/setup-signing.sh`, which imports the cert from the
  **`MACOS_SIGN_CERT_P12`** / **`MACOS_SIGN_CERT_PASSWORD`** secrets into a throwaway
  keychain and sets `QUILL_SIGN_IDENTITY`. Missing secret → `::warning::` + ad-hoc
  (same graceful-skip pattern as `TAP_TOKEN`). Because all distribution is via GitHub
  releases, **the cert must live in CI** (a local-only cert can't sign the DMGs users
  install) — use the *same* cert locally and in CI so local and released builds share
  one signature. `make-dmg.sh` only `ditto`s the app, so `build.sh`'s signature is
  what ships. (Gatekeeper still shows "unidentified developer" on first launch — that
  is separate from TCC and unchanged.)
- When the event tap fails to install (the only cause is a missing/stale Accessibility
  grant), `Shortcuts/ShortcutMonitor.swift` now surfaces a "grant Accessibility"
  notification instead of failing silently.

Local build — no Apple Developer account needed (ad-hoc signing via
`LocalBuild.xcconfig`, which also sets the `LOCAL_BUILD` flag, though the license
patch no longer depends on it):

```sh
make local      # raw build of the VoiceInk *target* → VoiceInk.app (NOT rebranded)
make dmg        # package that raw build to ~/Downloads/VoiceInk.dmg
make dev/run/clean
```

`make local`/`make dmg` are the low-level plumbing — they build the Xcode target and
produce an un-stamped **`VoiceInk.app`** (target name, upstream icon). For the actual
**Quill** product use the house-style scripts below, which stamp the Quill name +
bundle id + version + channel + channel-tinted icon:

```sh
./build.sh                                   # stable, version 0.<commit count> → build/Quill.app
QUILL_CHANNEL=nightly QUILL_BUILD=42 ./build.sh
./make-dmg.sh                                # package build/<App>.app → build/Quill[-Nightly].dmg
./dev.sh                                     # build Dev channel → /Applications/Quill Dev.app
./nightly.sh                                 # build Nightly channel locally → /Applications/Quill Nightly.app
```

After a build, drag `Quill.app` to `/Applications`, then grant **Microphone** +
**Accessibility** and download a Whisper model from Settings → AI Models
(`large-v3-turbo` for accuracy, `base.en` for lowest latency).

### App icon (`Scripts/`)

`Scripts/MakeIcon.swift` renders a 1024 icon (gradient squircle + white `waveform`
glyph); `Scripts/gen-icons.sh <channel>` tints it (stable=blue, nightly=amber,
dev=purple) and `sips`-downsamples into `AppIcon.appiconset`. The committed icon is
the stable blue one. `build.sh` temporarily swaps in the channel tint before the
xcodebuild (backing up + restoring the appiconset via a trap), so each channel
compiles its own colored icon and the working tree stays on stable.

## Update system (custom — Sparkle was removed)

This fork **replaced Sparkle** with a custom GitHub-Releases updater so it can never
pull the upstream developer's signed builds (which would clobber the patch).

- `VoiceInk/Channel.swift` — reads the `QuillChannel` Info.plist key. stable /
  nightly / dev map to display name (`Quill` / `Quill Nightly` / `Quill Dev`), bundle
  suffix (`com.syntaxlabtechnology.quill` [+`.nightly`/`.dev`]), DMG asset name, and
  whether updates run.
- `VoiceInk/Services/Updater.swift` — polls `rafay99-epic/Quill` Releases (public,
  no auth; the **repo** keeps the VoiceInk name even though the app is Quill). Stable →
  latest full release (`v0.<n>`, numeric compare); Nightly → newest pre-release
  (ordered by the `build <n>` parsed from the title, since the `nightly` tag is
  reused). Downloads the channel DMG (`Quill.dmg` / `Quill-Nightly.dmg`), mounts,
  replaces the bundle in place, relaunches.
- `UpdaterViewModel` in `VoiceInk.swift` wraps it and drives "Check for Updates…"
  (menus + Settings) with plain NSAlerts. The Settings "Auto-check Updates" toggle
  persists to `QuillAutoCheckUpdates` (**off by default**); when on, it checks at
  launch **and on a recurring 4h `Timer`** (`checkInterval`), guarded by
  `lastPromptedVersion` so it never re-nags for a version already dismissed. **No Sparkle, no appcast.xml, no EdDSA
  keys.** The `SU*` Info.plist keys and the upstream `announcementsURL` were removed/
  repointed off `beingpax.github.io`.
- If you re-sync upstream, do not re-add Sparkle or restore `SUFeedURL`.

### CI / release cycle (`.github/workflows/`, mirrors Crisp/Porter)

- `ci.yml` — `lint` (SwiftLint) gates. On a PR, `package` builds the DMG as an
  artifact. On push to `main`, `release` computes `VERSION=0.<commit count>`, builds
  via `./build.sh && ./make-dmg.sh`, and `gh release create v$VERSION build/Quill.dmg`.
- `nightly.yml` — push to `nightly` builds the Nightly channel and refreshes the
  single rolling `nightly` pre-release (title carries `build <run_number>`).
- whisper.xcframework is cached (`~/VoiceInk-Dependencies`, key `whisper-xcframework-v1`).
- `promotion.yml` — weekly (Thu 09:00 UTC) + on-demand. Diffs `main` vs `nightly`;
  if different, verifies nightly (lint + build) and runs `.github/scripts/promote.sh`,
  which sets `main`'s tree to `nightly` and pushes → triggers the Stable release. No
  manual step. **Needs the `PROMOTION_TOKEN` secret** (a PAT, *not* GITHUB_TOKEN —
  a GITHUB_TOKEN push to main won't trigger ci.yml; scopes: Contents R/W, PRs R/W,
  Workflows R/W).
- **Homebrew casks** live in the `rafay99-epic/homebrew-apps` tap (`quill` +
  `quill-nightly`). The release jobs auto-bump them via `.github/scripts/bump-cask.sh`
  — **needs the `TAP_TOKEN` secret** (fine-grained PAT, Contents R/W on
  `homebrew-apps`). Both cask-bump steps skip with a `::warning::` if the secret is
  absent, so a missing token never fails a release.
- **Branch model (house rule):** feature → `nightly` → PR; `main` is protected Stable.
  `.swiftlint.yml` is the permissive house config — if CI lint trips on inherited
  upstream code, add the rule to `disabled_rules` rather than churning files.

## Unlocked feature gates (beyond the license)

- **Insights / Peak Hours dashboard** (`Views/Dashboard/DashboardContent.swift`) — was
  gated behind a **30-minute total-usage** threshold (`canViewInsights`/
  `canViewPeakHours`), independent of license. Now unlocked: available as soon as
  stats load. (The `insightsUnlockDuration`/`peakHoursUnlockDuration` constants are
  left in place, unused.)
- Every payment-gated feature reads the neutered `LicenseViewModel`, so all are
  already unlocked; the usage-threshold Insights gate above was the only independent
  lock.

## First-run checklist (fresh machine)

1. `./build.sh` (or `./make-dmg.sh` for an installer)
2. Move `build/Quill.app` to `/Applications`, launch it (first launch: right-click → Open).
3. System Settings → Privacy & Security → grant **Microphone** and **Accessibility**.
4. Download a Whisper model in-app; set the dictation hotkey.
5. (Optional) point the AI-cleanup pass at a local Ollama model to keep the whole
   pipeline offline and free.
