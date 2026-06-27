import Foundation
import OSLog

/// Single source of truth for where Quill keeps everything on disk.
///
/// All Quill data lives under a **per-channel** home folder so the Stable and Dev
/// apps can run side by side on one machine without their models, recordings, or
/// SwiftData stores colliding — `~/.quill` for Stable, `~/.quill-dev` for Dev,
/// `~/.quill-nightly` for Nightly (see `Channel.dataFolderName`). The app is **not**
/// sandboxed (see `VoiceInk.entitlements`), so `homeDirectoryForCurrentUser` is the
/// user's real home directory and these are plain hidden folders there.
///
/// This replaces the old split layout, where runtime data sat in
/// `~/Library/Application Support/com.prakashjoshipax.VoiceInk` (plus a separate
/// `~/Library/Application Support/VoiceInk/CustomSounds`) and the build-time
/// whisper.cpp framework sat in `~/VoiceInk-Dependencies`.
///
/// `bootstrap()` runs a one-time, **non-destructive** migration of the runtime data
/// into this channel's folder: it *copies* the old files over and **never deletes
/// the originals**. Each channel migrates independently from the shared legacy
/// location into its own folder, so seeding Dev never disturbs Stable. That is
/// deliberate — an older Quill build (or another channel) that still reads the old
/// locations keeps working untouched. The cost is a one-time duplication on disk.
///
/// Note: the FluidAudio model cache (`~/Library/Application Support/FluidAudio`)
/// is intentionally left where it is — that path is dictated by the FluidAudio
/// SDK itself (see `FluidAudioModelManager`), so it cannot be relocated here. The
/// build-time whisper.cpp framework (`~/.quill/Dependencies`) is shared across
/// channels because it is build infrastructure referenced by the Xcode project, not
/// per-channel user data.
enum QuillPaths {
    /// This channel's data root — e.g. `~/.quill` (Stable) or `~/.quill-dev` (Dev).
    static let base: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(Channel.current.dataFolderName, isDirectory: true)

    /// Downloaded Whisper models (`~/.quill/WhisperModels`).
    static var whisperModels: URL { base.appendingPathComponent("WhisperModels", isDirectory: true) }

    /// Saved audio recordings (`~/.quill/Recordings`).
    static var recordings: URL { base.appendingPathComponent("Recordings", isDirectory: true) }

    /// User-imported notification sounds (`~/.quill/CustomSounds`).
    static var customSounds: URL { base.appendingPathComponent("CustomSounds", isDirectory: true) }

    private static let logger = Logger(subsystem: "com.syntaxlabtechnology.quill", category: "QuillPaths")

    /// Creates `~/.quill` if it does not exist.
    static func ensureBaseExists() {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// One-time bootstrap: ensure `~/.quill` exists and copy any runtime data left
    /// behind by the old Application Support layout into it. Safe to call on every
    /// launch — the migration runs only once (guarded by a `UserDefaults` flag),
    /// is idempotent (it skips anything already present), and must be called
    /// **before** the SwiftData container is opened so the `*.store` files are in
    /// place first.
    static func bootstrap() {
        ensureBaseExists()
        migrateLegacyStorageIfNeeded()
    }

    // MARK: - Migration

    // V2: the data root became per-channel (~/.quill, ~/.quill-dev, …). The key is
    // already scoped per channel via this build's UserDefaults domain (bundle id),
    // but the version bump re-runs the copy for installs that migrated under V1's
    // single shared ~/.quill so each channel reseeds into its own folder.
    private static let migrationDefaultsKey = "QuillStorageMigratedToHomeV2"

    private static func migrateLegacyStorageIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDefaultsKey) else { return }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            defaults.set(true, forKey: migrationDefaultsKey)
            return
        }

        // Old runtime root: ~/Library/Application Support/com.prakashjoshipax.VoiceInk
        // (held WhisperModels/, Recordings/, and the default/dictionary/stats stores,
        // including their -shm/-wal sidecar files). Merge its whole contents into ~/.quill.
        let legacyRoot = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        copyTree(from: legacyRoot, to: base, fm: fm)

        // Old custom sounds: ~/Library/Application Support/VoiceInk/CustomSounds
        let legacyCustomSounds = appSupport
            .appendingPathComponent("VoiceInk", isDirectory: true)
            .appendingPathComponent("CustomSounds", isDirectory: true)
        copyTree(from: legacyCustomSounds, to: customSounds, fm: fm)

        defaults.set(true, forKey: migrationDefaultsKey)
        logger.info("Completed one-time storage migration (copy) into \(base.path, privacy: .public)")
    }

    /// Recursively copies `source` into `destination`, **never deleting anything**:
    /// - directories are merged (the destination dir is created if missing, then
    ///   each child is copied into it),
    /// - files are copied only when the destination does not already exist, so a
    ///   value already present in `~/.quill` always wins and is never overwritten.
    private static func copyTree(from source: URL, to destination: URL, fm: FileManager) {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            if !fm.fileExists(atPath: destination.path) {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            guard let children = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
            for child in children {
                copyTree(from: child, to: destination.appendingPathComponent(child.lastPathComponent), fm: fm)
            }
            return
        }

        guard !fm.fileExists(atPath: destination.path) else {
            logger.info("Skipping \(source.lastPathComponent, privacy: .public): already present in ~/.quill")
            return
        }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: source, to: destination)
            logger.info("Copied \(source.lastPathComponent, privacy: .public) → \(destination.path, privacy: .public)")
        } catch {
            logger.error("Failed to copy \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
