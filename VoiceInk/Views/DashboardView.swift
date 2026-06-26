import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var licenseViewModel = LicenseViewModel()
    
    var body: some View {
        DashboardContent(
            modelContext: modelContext,
            licenseState: licenseViewModel.licenseState,
            onAddLicenseKey: navigateToLicenseManagement
        )
    }

    private func navigateToLicenseManagement() {
        // No-op: the Quill Pro / license page was removed (the app is always
        // licensed in this fork). This callback is unreachable — DashboardContent
        // only invokes it from the "add license key" prompt, which never shows
        // because licenseState is permanently `.licensed`.
    }
}
