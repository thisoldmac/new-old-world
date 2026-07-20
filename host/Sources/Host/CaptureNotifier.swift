import AppKit
import UserNotifications

/// Posts a system notification when a guest-initiated screenshot lands:
/// thumbnail attached, click opens the saved file. System notifications
/// (not a custom toast) because the arriving-while-buried case is exactly
/// the one that matters — the guest's human pressed Send to Host and this
/// Mac's user may not have the app frontmost.
@MainActor
final class CaptureNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let filePathKey = "nowCaptureFilePath"
    private var authorizationAsked = false

    /// Announce a delivered screenshot. `fileURL` is the landing-pad copy;
    /// nil (the save failed) still announces, just without click-to-open.
    func announce(guest: String, format: CaptureFormat, fileURL: URL?) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorizationIfNeeded(center)

        let content = UNMutableNotificationContent()
        content.title = "Screenshot from \(guest)"
        var line = "\(format.width) × \(format.height) · \(format.depth)-bit"
        if let fileURL {
            line += " · \(fileURL.lastPathComponent)"
            content.userInfo = [Self.filePathKey: fileURL.path]
            if let attachment = thumbnailAttachment(for: fileURL) {
                content.attachments = [attachment]
            }
        } else {
            line += " · could not be saved"
        }
        content.body = line
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }

    /// Announce a host-initiated menu capture. No attachment and no
    /// click-to-open: the image is already on the clipboard, which is where
    /// the person asked for it — the banner only has to confirm.
    func announce(outcome: QuickCaptureOutcome) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorizationIfNeeded(center)

        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = outcome.body
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }

    private func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) {
        guard !authorizationAsked else { return }
        authorizationAsked = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// The system MOVES attachment files into its own store, so the
    /// thumbnail must be a scratch copy — never the landing-pad original.
    private func thumbnailAttachment(for fileURL: URL)
        -> UNNotificationAttachment? {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-toast-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: fileURL, to: scratch)
            return try UNNotificationAttachment(identifier: "preview",
                                                url: scratch)
        } catch {
            return nil
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let path = info[Self.filePathKey] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
