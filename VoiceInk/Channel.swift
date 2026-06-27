import Foundation

/// Which build channel this app is. Baked into Info.plist (`QuillChannel`) by
/// `build.sh`; defaults to `.stable` when the key is absent (e.g. a plain Xcode
/// run or `make local`). The three channels install side by side because their
/// bundle ids differ:
///   • Stable  — your daily driver, updates from the latest GitHub release.
///   • Nightly — the integration channel, updates from the newest pre-release.
///   • Dev     — whatever branch you built locally: separate identity, no updater.
///
/// Mirrors the Channel enum in Crisp/Porter, adapted to Quill's bundle id
/// (`com.syntaxlabtechnology.quill`) and release asset names. (Quill is this
/// project's own identity — a fork of VoiceInk; the Xcode target is still named
/// VoiceInk internally, but the shipped product is Quill.)
enum Channel: String, Sendable {
    case stable
    case nightly
    case dev

    static let current: Channel = {
        let raw = Bundle.main.infoDictionary?["QuillChannel"] as? String
        return raw.flatMap(Channel.init(rawValue:)) ?? .stable
    }()

    /// Human-facing app name — matches `CFBundleName` and the `.app` on disk.
    var displayName: String {
        switch self {
        case .stable:  return "Quill"
        case .nightly: return "Quill Nightly"
        case .dev:     return "Quill Dev"
        }
    }

    /// Short corner-of-the-UI tag, nil on Stable.
    var badge: String? {
        switch self {
        case .stable:  return nil
        case .nightly: return "NIGHTLY"
        case .dev:     return "DEV"
        }
    }

    /// Suffix appended to `com.syntaxlabtechnology.quill` to form the bundle id.
    var bundleSuffix: String {
        switch self {
        case .stable:  return ""
        case .nightly: return ".nightly"
        case .dev:     return ".dev"
        }
    }

    /// Name of this channel's data folder in the home directory. Each channel keeps
    /// its own folder (`~/.quill`, `~/.quill-nightly`, `~/.quill-dev`) so Stable and
    /// Dev can run side by side on one machine without their models, recordings, or
    /// SwiftData stores ever touching each other — debugging Dev can never corrupt
    /// the Stable daily driver. See `QuillPaths`.
    var dataFolderName: String {
        switch self {
        case .stable:  return ".quill"
        case .nightly: return ".quill-nightly"
        case .dev:     return ".quill-dev"
        }
    }

    /// The published DMG asset name for this channel. nil for Dev, which never
    /// publishes a release. The updater matches releases by this exact name.
    var assetName: String? {
        switch self {
        case .stable:  return "Quill.dmg"
        case .nightly: return "Quill-Nightly.dmg"
        case .dev:     return nil
        }
    }

    /// Stable tracks the latest full release; Nightly tracks the newest
    /// pre-release. (Dev tracks nothing — see `updatesEnabled`.)
    var isPrerelease: Bool { self == .nightly }

    /// Dev has no updater at all. Stable and Nightly both update from their feeds.
    var updatesEnabled: Bool { self != .dev }

    /// Extra build detail (branch@sha), baked in for Nightly and Dev so the About
    /// screen can show exactly what's running. nil on Stable.
    static var buildInfo: String? {
        Bundle.main.infoDictionary?["QuillBuildInfo"] as? String
    }
}
