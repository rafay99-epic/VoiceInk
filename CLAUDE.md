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

The identifier is now **unified across the whole app**: every `com.prakashjoshipax.*`
literal (the `os.Logger` subsystem strings, `DispatchQueue` labels, the Keychain
service name, the in-code iCloud CloudKit container, and the old Application Support
folder name) was rewritten to **`com.syntaxlabtechnology.quill`**. Earlier this fork
left the ~50 logger/queue literals untouched as a "small diff" tradeoff; that was
reversed deliberately so the bundle id, entitlements, and code all read the same
string. On an upstream merge, re-apply this rename to any reintroduced
`com.prakashjoshipax.*` literals. (Renaming the Keychain service orphans
previously-saved API keys in signed builds — they get re-entered once; `LOCAL_BUILD`
keeps keys in `UserDefaults`, so dev builds are unaffected.)

### On-disk storage (`~/.quill`, per channel) — third deviation from upstream

All Quill runtime data lives under a **per-channel home folder** (the app is not
sandboxed, so this is the real home dir), not in `~/Library/Application Support`:
**`~/.quill`** for Stable, **`~/.quill-dev`** for Dev, **`~/.quill-nightly`** for
Nightly (`Channel.dataFolderName`). This isolation is load-bearing — one machine
runs the Stable daily driver and a Dev build at once, and debugging Dev must never
touch Stable's models, history, or stores. The single source of truth is
**`VoiceInk/Services/QuillPaths.swift`** — `QuillPaths.base` (this channel's folder)
plus `whisperModels` / `recordings` / `customSounds`, and the SwiftData `*.store`
files sit directly in `base`. Every path site funnels through it; don't reintroduce
`FileManager…applicationSupportDirectory…appendingPathComponent("com.…")` paths and
don't hardcode `~/.quill` — go through `QuillPaths`/`Channel`.
`QuillPaths.bootstrap()` runs once at the top of `VoiceInkApp.init()` (before the
SwiftData container opens) and performs a **non-destructive** migration: it
*copies* existing data from the old `…/Application Support/com.prakashjoshipax.VoiceInk`
and `…/Application Support/VoiceInk/CustomSounds` folders into this channel's folder
and **never deletes the originals**, so an older build or another channel that still
reads the old paths keeps working. Each channel migrates independently from the
shared legacy location into its own folder, so seeding Dev never disturbs Stable.
The copy is a recursive merge (skips any file already present, so it's idempotent)
guarded by the per-channel `QuillStorageMigratedToHomeV2` UserDefaults flag (bumped
from V1 when the layout went per-channel). Do not change the copy to a move —
deleting the old data risks corrupting an older co-installed version.

**Exception:** the FluidAudio model cache stays at
`~/Library/Application Support/FluidAudio/Models` — that path is dictated by the
FluidAudio SDK itself (`FluidAudioModelManager` only mirrors it), so it can't move.

Build-time deps moved too: the whisper.cpp clone/xcframework is now
`~/.quill/Dependencies` (was `~/VoiceInk-Dependencies`) — see the `Makefile`,
`ci.yml` cache, and the `whisper.xcframework` `path` in `project.pbxproj`. This one
is **channel-neutral on purpose** (always `~/.quill/Dependencies`, never
`~/.quill-dev/…`): it's build infrastructure referenced by the shared Xcode project,
not per-channel user data, so every channel builds against the same framework. The
runtime migration never touches it, and `make clean` removes only it, never user data.

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
- **`dev.sh` auto-prefers the stable cert:** if `QUILL_SIGN_IDENTITY` is unset it uses
  the conventional **`Quill Local Signing`** identity when that cert exists in the
  keychain (so dev builds keep one signature and the Accessibility grant survives every
  rebuild); if it's missing, `dev.sh` prints a one-time hint to run `make-signing-cert.sh`
  and falls back to ad-hoc. This is why the onboarding "Recheck" silently fails on plain
  ad-hoc dev builds — the rebuilt binary's CDHash no longer matches the old TCC grant, so
  `AXIsProcessTrusted()` correctly returns `false`. Onboarding now also shows an
  Accessibility recovery hint (toggle off/on + relaunch) for this case.
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
./make-dmg.sh                                # package build/Quill.app → build/Quill.dmg
./dev.sh                                     # build Dev channel → /Applications/Quill Dev.app (local testing)
```

(The Nightly channel was retired — `nightly.sh` and the `nightly`/`promotion`
workflows are gone. `build.sh`/`Channel.swift` still *accept* `QUILL_CHANNEL=nightly`
as dead-but-harmless code; don't use it.)

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
  `lastPromptedVersion` so it won't re-nag for a version already dismissed **within
  the same app session** (`lastPromptedVersion` is in-memory, not persisted, so a
  relaunch can prompt again for that version). **No Sparkle, no appcast.xml, no EdDSA
  keys.** The `SU*` Info.plist keys and the upstream `announcementsURL` were removed/
  repointed off `beingpax.github.io`.
- If you re-sync upstream, do not re-add Sparkle or restore `SUFeedURL`.

### CI / release cycle (`.github/workflows/`)

Only **`ci.yml`** remains — the old `nightly.yml` and `promotion.yml` (the Nightly
channel + weekly auto-promotion) were **removed**; the model is now just **dev →
stable** (see Branch model below).

- `ci.yml` — `lint` (SwiftLint) gates. On a **PR**, `package` builds the DMG as an
  artifact (**ad-hoc** signed — deliberately no signing step there, so a PR branch
  never receives the signing secrets). On push to `main`, `release` computes
  `VERSION=0.<commit count>`, imports the stable cert via
  `.github/scripts/setup-signing.sh`, builds via `./build.sh && ./make-dmg.sh`, and
  `gh release create v$VERSION build/Quill.dmg`.
- whisper.xcframework is cached (`~/.quill/Dependencies`, key `whisper-xcframework-v2`).
- **Homebrew cask** — the `quill` cask lives in the `rafay99-epic/homebrew-apps` tap;
  the release job auto-bumps it via `.github/scripts/bump-cask.sh` (**needs the
  `TAP_TOKEN` secret**, fine-grained PAT, Contents R/W on `homebrew-apps`; skips with
  a `::warning::` if absent so a missing token never fails a release). The old
  `quill-nightly` cask is now orphaned — clean it from the tap when convenient.
- The `PROMOTION_TOKEN` secret is no longer used (promotion.yml is gone); leave or
  delete it.
- **Branch model (house rule):** work on **`dev`** → test locally with `./dev.sh`
  (installs `/Applications/Quill Dev.app`; the Dev channel is local-only —
  `make-dmg.sh` refuses it) → open a PR **`dev` → `main`** (CI builds a test DMG
  artifact) → merge to `main` to cut the Stable release. `main` is protected Stable.
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
