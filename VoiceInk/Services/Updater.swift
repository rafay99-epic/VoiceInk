import Foundation
import AppKit
import os

/// Channel-aware GitHub-release updater. Replaces Sparkle — this fork publishes its
/// own releases to `rafay99-epic/VoiceInk` and must never pull the upstream
/// developer's builds (which would clobber the unlocked patch).
///   • Stable  → newest full release; compares the numeric version `0.<n>`.
///   • Nightly → newest pre-release; compares the monotonic build number parsed
///     from the release title ("… build <n>").
///   • Dev     → disabled (`Channel.updatesEnabled == false`).
///
/// Checks the public Releases API (no auth — the fork is public). On install it
/// downloads the channel's DMG, mounts it, replaces the running bundle in place,
/// and relaunches — falling back to opening the DMG in Finder if an in-place
/// replace isn't possible (e.g. the app lives somewhere it can't write).
///
/// Mirrors Porter's `Updater`, adapted to VoiceInk (os.Logger, UserDefaults).
@MainActor
final class Updater {
    /// `owner/repo` the releases are published to. Must match the GitHub repo.
    static let repoSlug = "rafay99-epic/Quill"

    /// Persisted "check automatically on launch" preference. Off by default — this
    /// fork is deliberately conservative about replacing the patched build.
    static let autoCheckDefaultsKey = "QuillAutoCheckUpdates"

    struct Available: Equatable {
        let version: String
        let title: String
        let dmgURL: URL
        let buildNumber: Int?
    }

    /// Result of a feed check. `unavailable` (busy / Dev channel / network or parse
    /// error) is distinct from `upToDate` so a manual check that overlaps a running
    /// auto-check never falsely reports "you're up to date".
    enum CheckOutcome {
        case update(Available)
        case upToDate
        case unavailable
    }

    private(set) var available: Available?
    private(set) var isChecking = false
    private(set) var isInstalling = false

    private let logger = Logger(subsystem: "com.syntaxlabtechnology.quill", category: "Updater")

    var isBusy: Bool { isChecking || isInstalling }

    // MARK: - Version of the running app

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static var currentBuildNumber: Int {
        Int(Bundle.main.infoDictionary?["QuillBuildNumber"] as? String ?? "") ?? 0
    }

    // MARK: - Check

    /// Check the feed. `.update` if a newer release exists, `.upToDate` if not, and
    /// `.unavailable` if the check couldn't run (channel disabled, already busy, or
    /// the request failed) — the caller must NOT treat `.unavailable` as up to date.
    func check() async -> CheckOutcome {
        guard Channel.current.updatesEnabled, !isBusy else { return .unavailable }
        isChecking = true
        defer { isChecking = false }

        do {
            let releases = try await fetchReleases()
            guard let best = pickBest(from: releases), isNewer(best) else {
                available = nil
                return .upToDate
            }
            available = best
            logger.info("update available: \(best.version, privacy: .public) (build \(best.buildNumber ?? -1))")
            return .update(best)
        } catch {
            logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    // MARK: - Install

    /// Download + install the given release, then relaunch. Returns false if the
    /// in-place replace wasn't possible (caller should hand the DMG to the user).
    @discardableResult
    func install(_ release: Available) async -> Bool {
        guard !isInstalling else { return false }
        isInstalling = true
        defer { isInstalling = false }

        do {
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmgURL)
            let dmg = downloaded.deletingPathExtension().appendingPathExtension("dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            if try replaceInPlace(fromDMG: dmg) {
                logger.info("update installed: \(release.version, privacy: .public) — relaunching")
                relaunch()
                return true
            } else {
                NSWorkspace.shared.open(dmg)
                return false
            }
        } catch {
            logger.error("update install failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - GitHub API

    private func fetchReleases() async throws -> [GHRelease] {
        // Public repo — no auth needed.
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([GHRelease].self, from: data)
    }

    /// The newest release matching this channel that ships the channel's DMG.
    private func pickBest(from releases: [GHRelease]) -> Available? {
        let wantPrerelease = Channel.current.isPrerelease
        let assetName = Channel.current.assetName
        for release in releases where release.prerelease == wantPrerelease {
            guard let asset = release.assets.first(where: { $0.name == assetName }) else { continue }
            let title = release.name ?? release.tagName ?? ""
            return Available(
                version: (release.tagName ?? title).replacingOccurrences(of: "v", with: ""),
                title: title,
                dmgURL: asset.browserDownloadURL,
                buildNumber: Self.parseBuild(from: title))
        }
        return nil
    }

    private func isNewer(_ candidate: Available) -> Bool {
        if Channel.current.isPrerelease {
            guard let candidateBuild = candidate.buildNumber else { return false }
            return candidateBuild > Self.currentBuildNumber
        }
        return Self.compareNumeric(candidate.version, Self.currentVersion) > 0
    }

    // MARK: - Parsing helpers

    static func parseBuild(from title: String) -> Int? {
        guard let range = title.range(of: #"build\s+(\d+)"#, options: .regularExpression) else { return nil }
        return Int(title[range].filter(\.isNumber))
    }

    /// Compare `0.<n>`-style versions component-wise. Returns >0 if `a` is newer.
    static func compareNumeric(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map(String.init)?
                .split(separator: ".").map { Int($0) ?? 0 } ?? []
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    // MARK: - DMG install

    /// Mount the DMG, copy the contained `.app` over the running bundle, detach.
    /// Returns false (rather than throwing) when the destination isn't writable, so
    /// the caller can fall back to opening the DMG.
    private func replaceInPlace(fromDMG dmg: URL) throws -> Bool {
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-update-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-mountpoint", mountPoint.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let appName = "\(Channel.current.displayName).app"
        let newApp = mountPoint.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            logger.error("DMG didn't contain \(appName, privacy: .public)")
            return false
        }

        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            return false
        }
        let backup = dest.appendingPathExtension("old")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: dest, to: backup)
        do {
            try run("/usr/bin/ditto", [newApp.path, dest.path])
            try? FileManager.default.removeItem(at: backup)
            return true
        } catch {
            // Roll back to the backup so we don't leave the user with no app.
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: backup, to: dest)
            throw error
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed: \(output)"])
        }
        return output
    }
}

// GitHub Releases API DTOs — file-scoped so their CodingKeys aren't nested too deep.
private struct GHRelease: Decodable {
    let name: String?
    let tagName: String?
    let prerelease: Bool
    let assets: [GHAsset]
    enum CodingKeys: String, CodingKey { case name, prerelease, assets, tagName = "tag_name" }
}

private struct GHAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
}
