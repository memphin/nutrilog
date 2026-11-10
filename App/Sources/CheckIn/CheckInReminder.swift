import Foundation
import UserNotifications

/// The weekly check-in reminder: one repeating local notification on the check-in weekday (backlog #35).
/// Off by default; the user turns it on in Settings → Weekly check-in.
protocol CheckInReminderScheduling: Sendable {
    /// Asks for notification permission if needed; false when the user declined.
    func requestAuthorization() async -> Bool
    /// Replaces the reminder with one on `weekday` (1 = Sunday … 7 = Saturday) at `hour`:00.
    func schedule(weekday: Int, hour: Int) async throws
    func cancel() async
}

/// Tests, previews: nothing is scheduled.
struct NoCheckInReminder: CheckInReminderScheduling {
    func requestAuthorization() async -> Bool {
        true
    }

    func schedule(weekday _: Int, hour _: Int) async throws {}
    func cancel() async {}
}

struct LocalNotificationCheckInReminder: CheckInReminderScheduling {
    static let identifier = "weekly-check-in"
    static let defaultHour = 9

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func schedule(weekday: Int, hour: Int) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        let content = UNMutableNotificationContent()
        content.title = "Weekly check-in"
        content.body = "See how your weight moved this week and review your calorie target."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Self.components(weekday: weekday, hour: hour), repeats: true)
        try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }

    func cancel() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    static func components(weekday: Int, hour: Int) -> DateComponents {
        DateComponents(hour: min(max(hour, 0), 23), minute: 0, weekday: min(max(weekday, 1), 7))
    }
}
