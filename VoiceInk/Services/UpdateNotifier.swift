import Foundation
import UserNotifications

/// Posts a macOS **system notification** (Notification Center) when a Quill update
/// is available, with an "Install" action. Tapping the notification — or its
/// Install action — posts `.updateInstallRequested`, which `UpdaterViewModel`
/// observes to re-check and install. Routing through a NotificationCenter post
/// (rather than a captured closure) means the action still works after an app
/// restart: there's no in-memory handler to go stale, and nothing is retained.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    private let categoryID = "QUILL_UPDATE"
    private let installActionID = "QUILL_UPDATE_INSTALL"
    private let requestID = "quill-update-available"
    private var didRegisterCategory = false

    private override init() { super.init() }

    /// Register the delegate + Install-action category at app launch, so a
    /// notification delivered in a *previous* session can still be handled when
    /// tapped now (otherwise the delegate is set only after a notification is posted
    /// this session, and tapping a persisted one would be a no-op). Call once on launch.
    func activate() {
        registerCategoryIfNeeded(UNUserNotificationCenter.current())
    }

    /// Request permission (once) and post the update notification.
    func notifyUpdateAvailable(version: String) {
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

    // Tapping the notification (default action) or its "Install" action asks the
    // updater to install — via a NotificationCenter post, so it survives a restart.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == installActionID || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NotificationCenter.default.post(name: .updateInstallRequested, object: nil)
        }
        completionHandler()
    }
}
