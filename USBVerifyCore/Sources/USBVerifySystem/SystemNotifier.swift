import Foundation
import USBVerifyCore
import UserNotifications

public final class SystemNotifier: Notifier, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var requested = false

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func notify(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let shouldRequest = markAuthorizationRequested()
        if shouldRequest {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    private func markAuthorizationRequested() -> Bool {
        lock.withLock {
            let shouldRequest = !requested
            requested = true
            return shouldRequest
        }
    }
}
