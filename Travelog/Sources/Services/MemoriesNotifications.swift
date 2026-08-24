import Foundation
import UserNotifications

/// Daily local notification nudging the user to revisit "On This Day".
enum MemoriesNotifications {
    static let identifier = "onThisDayDaily"

    /// Returns false if the user denied notification permission.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your memories are waiting")
        content.body = String(localized: "Relive the photos you took on this day in past years.")
        content.sound = .default

        var components = DateComponents()
        components.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        return true
    }

    static func disable() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
