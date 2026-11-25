import Foundation
import UserNotifications

@MainActor
final class GuardNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GuardNotifications()

    func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do { return try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { return false }
    }

    func report(title: String, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
