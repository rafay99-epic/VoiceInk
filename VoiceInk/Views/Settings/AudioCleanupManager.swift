import Foundation
import SwiftData

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    private var completionObserver: NSObjectProtocol?
    private var modelContext: ModelContext?
    private let cleanupCheckInterval: TimeInterval = 86400 // Check once per day (in seconds)
    // Orphan files younger than this are never swept, so an "Immediately" retention
    // can't delete a recording whose transcription is still in flight.
    private let orphanGracePeriod: TimeInterval = 3600

    private init() {}

    /// Start the automatic cleanup schedule.
    func startAutomaticCleanup(modelContext: ModelContext) {
        self.modelContext = modelContext

        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.runAutomaticCleanupIfNeeded(modelContext: modelContext)
            }
        }

        // With an "Immediately" retention period, delete each recording as soon as
        // its transcription is saved rather than waiting for the daily sweep.
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
        }
        completionObserver = NotificationCenter.default.addObserver(
            forName: .transcriptionCompleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let transcription = notification.object as? Transcription else { return }
            Task { await self.deleteAudioImmediatelyIfConfigured(for: transcription) }
        }
    }

    /// Run automatic cleanup once if it is due. This is safe to call on app/window appear.
    func runAutomaticCleanupIfNeeded(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
              !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
              shouldRunAutomaticCleanup() else {
            return
        }

        await performCleanup(modelContext: modelContext)
        UserDefaults.standard.set(Date(), forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate)
    }
    
    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
            self.completionObserver = nil
        }
    }

    /// Delete a transcription's audio right after it completes when retention is "Immediately" (0 days)
    private func deleteAudioImmediatelyIfConfigured(for transcription: Transcription) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
              !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
              UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod) == 0,
              let modelContext else { return }

        await MainActor.run {
            guard let urlString = transcription.audioFileURL,
                  let url = URL(string: urlString),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
                transcription.audioFileURL = nil
                try? modelContext.save()
            } catch {
                // Skip - the daily sweep will retry
            }
        }
    }
    
    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (fileCount: Int, totalSize: Int64, transcriptions: [Transcription], orphanFiles: [URL]) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [], [])
        }

        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)

                // Calculate stats (can be done on any thread)
                var fileCount = 0
                var totalSize: Int64 = 0
                var eligibleTranscriptions: [Transcription] = []

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString),
                       FileManager.default.fileExists(atPath: url.path) {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                           let fileSize = attributes[.size] as? Int64 {
                            totalSize += fileSize
                            fileCount += 1
                            eligibleTranscriptions.append(transcription)
                        }
                    }
                }

                let referencedFileNames = try self.fetchReferencedFileNames(modelContext)
                let orphanFiles = self.findOrphanFiles(olderThan: self.orphanCutoff(from: cutoffDate), referencedFileNames: referencedFileNames)
                for orphanURL in orphanFiles {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: orphanURL.path),
                       let fileSize = attributes[.size] as? Int64 {
                        totalSize += fileSize
                    }
                    fileCount += 1
                }

                return (fileCount, totalSize, eligibleTranscriptions, orphanFiles)
            }
        } catch {
            return (0, 0, [], [])
        }
    }
    
    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            // Execute SwiftData operations on the main thread
            try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)
                var deletedCount = 0

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString),
                       FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try FileManager.default.removeItem(at: url)
                            transcription.audioFileURL = nil
                            deletedCount += 1
                        } catch {
                            // Skip this file - don't update audioFileURL if deletion failed
                        }
                    }
                }

                if deletedCount > 0 {
                    try modelContext.save()
                }

                // Sweep recordings no transcription references (failed or cancelled sessions),
                // respecting the same retention window so in-flight recordings are never touched.
                let referencedFileNames = try self.fetchReferencedFileNames(modelContext)
                for orphanURL in self.findOrphanFiles(olderThan: self.orphanCutoff(from: cutoffDate), referencedFileNames: referencedFileNames) {
                    try? FileManager.default.removeItem(at: orphanURL)
                }
            }
        } catch {
            // Silently fail - cleanup is non-critical
        }
    }
    
    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }

    private func shouldRunAutomaticCleanup() -> Bool {
        guard let lastCleanupDate = UserDefaults.standard.object(forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) as? Date else {
            return true
        }

        return Date().timeIntervalSince(lastCleanupDate) >= cleanupCheckInterval
    }
    
    /// Run cleanup on the specified transcriptions and orphan files
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription], orphanFiles: [URL] = []) async -> (deletedCount: Int, errorCount: Int) {
        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                var deletedCount = 0
                var errorCount = 0

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString),
                       FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try FileManager.default.removeItem(at: url)
                            transcription.audioFileURL = nil
                            deletedCount += 1
                        } catch {
                            errorCount += 1
                        }
                    }
                }

                for orphanURL in orphanFiles where FileManager.default.fileExists(atPath: orphanURL.path) {
                    do {
                        try FileManager.default.removeItem(at: orphanURL)
                        deletedCount += 1
                    } catch {
                        errorCount += 1
                    }
                }

                if deletedCount > 0 || errorCount > 0 {
                    try? modelContext.save()
                }

                return (deletedCount, errorCount)
            }
        } catch {
            return (0, 0)
        }
    }

    /// File names of every recording still referenced by a transcription record
    private func fetchReferencedFileNames(_ modelContext: ModelContext) throws -> Set<String> {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.audioFileURL]

        let transcriptions = try modelContext.fetch(descriptor)
        return Set(transcriptions.compactMap { transcription -> String? in
            guard let urlString = transcription.audioFileURL,
                  let url = URL(string: urlString) else { return nil }
            return url.lastPathComponent
        })
    }

    /// Retention cutoff for orphan files, never closer to now than the grace period
    private func orphanCutoff(from cutoffDate: Date) -> Date {
        min(cutoffDate, Date().addingTimeInterval(-orphanGracePeriod))
    }

    /// Recordings on disk that no transcription references and that predate the cutoff
    private func findOrphanFiles(olderThan cutoffDate: Date, referencedFileNames: Set<String>) -> [URL] {
        let recordingsDirectory = QuillPaths.recordings
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: recordingsDirectory,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return [] }

        return files.filter { fileURL in
            guard !referencedFileNames.contains(fileURL.lastPathComponent),
                  let modifiedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return false
            }
            return modifiedDate < cutoffDate
        }
    }
    
    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
} 
