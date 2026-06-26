import Foundation
import UserNotifications

/// Posts a macOS **system notification** (Notification Center) when a Quill update
/// is available, with an "Install" action button. Tapping the notification — or its
/// Install action — runs the stored install handler. This is separate from the
/// app's in-app banner (`NotificationManager`); the updater fires both.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    private let categoryID = "QUILL_UPDATE"
    private let installActionID = "QUILL_UPDATE_INSTALL"
    private let requestID = "quill-update-available"

    /// Hops to the main actor internally — safe to call from the notification
    /// delegate (which the system invokes off the main thread).
    private var installHandler: (() -> Void)?
    private var didRegisterCategory = false

    private override init() { super.init() }

    /// Request permission (once) and post the update notification.
    func notifyUpdateAvailable(version: String, onInstall: @escaping () -> Void) {
        installHandler = onInstall
        let center = UNUserNotificationCenter.current()
        registerCategoryIfNeeded(center)

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Quill update available")
            content.body = String(format: String(localized: "Quill %@ is ready to install."), version)
            content.categoryIdentifier = self.categoryID
            content.sound = .default

            let request = UNNotificationRequest(identifier: self.requestID, content: content, trigger: nil)
            center.add(request)
        }
    }

    private func registerCategoryIfNeeded(_ center: UNUserNotificationCenter) {
        guard !didRegisterCategory else { return }
        didRegisterCategory = true
        center.delegate = self
        let install = UNNotificationAction(
            identifier: installActionID,
            title: String(localized: "Install"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [install],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // Show the banner even when Quill is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tapping the notification (default action) or its "Install" action installs.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == installActionID || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            installHandler?()
        }
        completionHandler()
    }
}
