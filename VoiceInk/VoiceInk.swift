import SwiftUI
import SwiftData
import AppKit
import OSLog
import AppIntents
import FluidAudio

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    // Persisted so the menu bar item's visibility survives relaunch and stays in
    // sync with the Settings toggle (both read this same key).
    @AppStorage("ShowMenuBarIcon") private var showMenuBarIcon = true
    @State private var didShowAccessibilityReminder = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        AppDefaults.registerDefaults()
        AppLanguagePreference.applyStored()
        AppAppearancePreference.applyStored()
        OnboardingV2Migration.prepareIfNeeded()

        // Ensure ~/.quill exists and migrate any data from the old Application
        // Support layout BEFORE the SwiftData container opens the *.store files.
        QuillPaths.bootstrap()

        let logger = Logger(subsystem: "com.syntaxlabtechnology.quill", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(localized: "VoiceInk couldn't access its storage location. Your transcriptions will not be saved between sessions.")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical("❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)")
                fatalError("VoiceInk failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)")
            }
        }

        container = resolvedContainer
        DictionaryService.removeExactDuplicateContent(context: resolvedContainer.mainContext, source: "launch")

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        let modelsDirectory = QuillPaths.whisperModels

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: resolvedContainer, engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
        }

        AppShortcuts.updateAppShortcutParameters()

        let migrationTask = SessionMetricMigrationService.shared.runIfNeeded(modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task {
            await migrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let dataDirectory = QuillPaths.base

        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let defaultStoreURL = dataDirectory.appendingPathComponent("default.store")
        let dictionaryStoreURL = dataDirectory.appendingPathComponent("dictionary.store")
        let statsStoreURL = dataDirectory.appendingPathComponent("stats.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        #if LOCAL_BUILD
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private("iCloud.com.syntaxlabtechnology.quill")
        #endif
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            if enableAnnouncements {
                                AnnouncementsService.shared.start()
                            }

                            showAccessibilityReminderIfNeeded()

                            // Run due audio-only cleanup and schedule future checks when transcript cleanup is not managing retention.
                            if !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) &&
                                UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled) {
                                Task {
                                    await audioCleanupManager.runAutomaticCleanupIfNeeded(modelContext: container.mainContext)
                                }
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                        .onDisappear {
                            AnnouncementsService.shared.stop()
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: AppWindowLayout.width)
                        .frame(minHeight: AppWindowLayout.minimumHeight)
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 22
                $0.size.width = 22 / ratio
                return $0
            }(NSImage(named: "menuBarIcon")!)

            Image(nsImage: image)
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
        WindowGroup("Debug") {
            Button("Toggle Menu Bar Only") {
                menuBarManager.isMenuBarOnly.toggle()
            }
        }
        #endif
    }

    private func showAccessibilityReminderIfNeeded() {
        guard !didShowAccessibilityReminder else { return }
        didShowAccessibilityReminder = true

        guard !AXIsProcessTrusted() else { return }

        NotificationManager.shared.showNotification(
            title: String(localized: "Accessibility permission is not provided"),
            type: .warning,
            duration: 7.0,
            actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
        )
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Drives the custom GitHub-release `Updater` (Sparkle was removed — see
/// `Services/Updater.swift`). Keeps the same surface the menus/settings expect:
/// `canCheckForUpdates`, `automaticallyChecksForUpdates`, `checkForUpdates()`,
/// `setAutomaticallyChecksForUpdates(_:)`.
@MainActor
class UpdaterViewModel: ObservableObject {
    private let updater = Updater()

    /// How often to auto-check while the app is running. 4 hours — the same cadence
    /// the old Sparkle feed used (SUScheduledCheckInterval = 14400s).
    private let checkInterval: TimeInterval = 4 * 60 * 60
    private var checkTimer: Timer?
    /// Retained so the block-based observer can be removed in `deinit`.
    private var installObserver: NSObjectProtocol?
    /// The version we last surfaced a prompt for, so the recurring timer doesn't
    /// re-nag every interval for an update the user already saw (and dismissed).
    private var lastPromptedVersion: String?
    /// Guards against concurrent install triggers (banner tap + action button +
    /// notification + manual prompt can all fire `startInstall`). Without it a
    /// second trigger could start another install and show a duplicate
    /// "Finish installing" prompt. @MainActor-isolated, so a plain Bool is safe.
    private var isInstalling = false

    /// Always enabled for Stable/Nightly; disabled on the Dev channel (no feed).
    @Published var canCheckForUpdates = Channel.current.updatesEnabled
    @Published var automaticallyChecksForUpdates =
        UserDefaults.standard.bool(forKey: Updater.autoCheckDefaultsKey)

    init() {
        // Register the update-notification delegate now (at launch) so tapping a
        // notification delivered in a previous session is still handled.
        UpdateNotifier.shared.activate()
        // Check once on launch, then keep a recurring timer running while enabled.
        Task { @MainActor in await autoCheck() }
        startOrStopTimer()
        // The system update notification's Install action (and tap) posts this —
        // re-check the feed and install. Routed through NotificationCenter so it
        // works even after a restart (no captured in-memory handler).
        installObserver = NotificationCenter.default.addObserver(
            forName: .updateInstallRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installLatestIfAvailable() }
        }
    }

    deinit {
        if let installObserver {
            NotificationCenter.default.removeObserver(installObserver)
        }
        checkTimer?.invalidate()
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        automaticallyChecksForUpdates = value
        UserDefaults.standard.set(value, forKey: Updater.autoCheckDefaultsKey)
        startOrStopTimer()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        canCheckForUpdates = false
        Task { @MainActor in
            defer { canCheckForUpdates = Channel.current.updatesEnabled }
            switch await updater.check() {
            case .update(let available):
                lastPromptedVersion = available.version
                presentUpdatePrompt(available)
            case .upToDate:
                presentInfo(title: String(localized: "You're up to date"),
                            message: String(format: String(localized: "Quill %@ is the latest version."), Updater.currentVersion))
            case .unavailable:
                break // busy / channel disabled / network error — don't claim "up to date"
            }
        }
    }

    // MARK: - Auto-check (launch + recurring timer)

    /// (Re)build the recurring check timer to match the current toggle + channel.
    /// Called on launch and whenever the auto-check setting changes.
    private func startOrStopTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
        guard automaticallyChecksForUpdates, Channel.current.updatesEnabled else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoCheck() }
        }
        timer.tolerance = 10 * 60 // 10-min slack lets macOS coalesce wakeups (battery-friendly)
        checkTimer = timer
    }

    /// Silent background check (launch + timer). Only prompts when a *newer* version
    /// appears, and never twice for the same version in one run.
    private func autoCheck() async {
        guard automaticallyChecksForUpdates, Channel.current.updatesEnabled else { return }
        guard case .update(let available) = await updater.check(),
              available.version != lastPromptedVersion else { return }
        // Re-validate after the awaited check: the user may have toggled auto-check
        // off (or the channel changed) mid-request — don't notify if so.
        guard automaticallyChecksForUpdates, Channel.current.updatesEnabled else { return }
        lastPromptedVersion = available.version
        surfaceUpdate(available)
    }

    /// Triggered by the system update notification's Install action. Re-checks the
    /// feed and installs if an update is still available — relies on no in-memory
    /// state, so it works even if the app was restarted since the notification.
    func installLatestIfAvailable() {
        Task { @MainActor in
            if case .update(let available) = await updater.check() {
                startInstall(available)
            }
        }
    }

    /// Background update found → surface it without interrupting: a small in-app
    /// banner (with an "Update" action) AND a macOS system notification (with an
    /// "Install" action). Either one installs. (Manual checks use the NSAlert below.)
    private func surfaceUpdate(_ available: Updater.Available) {
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Quill %@ available"), available.version),
            type: .info,
            duration: 10,
            onTap: { [weak self] in self?.startInstall(available) },
            actionButton: (label: String(localized: "Update"), action: { [weak self] in self?.startInstall(available) })
        )
        UpdateNotifier.shared.notifyUpdateAvailable(version: available.version)
    }

    private func presentUpdatePrompt(_ available: Updater.Available) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Update Available")
        alert.informativeText = String(
            format: String(localized: "Quill %@ is available (you're on %@). Install and relaunch?"),
            available.version, Updater.currentVersion)
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startInstall(available)
    }

    /// Download + install the update, then relaunch. If an in-place replace wasn't
    /// possible the DMG is opened — tell the user to finish by dragging it in.
    private func startInstall(_ available: Updater.Available) {
        guard !isInstalling else { return }
        isInstalling = true
        Task { @MainActor in
            defer { isInstalling = false }
            let installed = await updater.install(available)
            if !installed {
                presentInfo(title: String(localized: "Finish installing"),
                            message: String(localized: "The update was downloaded and opened. Drag Quill into Applications to finish."))
            }
        }
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
