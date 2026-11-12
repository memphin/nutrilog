import Core
import Foundation
import UserNotifications

/// The hydration reminder (spec §4): one pending local notification, replaced whenever the plan changes, with a
/// "+ 250 ml" action that logs water in the background. Off by default; Settings → Hydration turns it on.
protocol HydrationReminderScheduling: Sendable {
    /// Asks for notification permission if needed; false when the user declined.
    func requestAuthorization() async -> Bool
    /// True when notifications are already allowed. Never asks: for background recomputes.
    func isAuthorized() async -> Bool
    /// Replaces the reminder with one at `date` (or right away when `date` has passed); `actionTitle` names the
    /// add-water action.
    func schedule(at date: Date, title: String, body: String, actionTitle: String) async throws
    /// Removes the pending reminder and one still shown in Notification Center.
    func cancel() async
}

/// Tests, previews: nothing is scheduled.
struct NoHydrationReminder: HydrationReminderScheduling {
    func requestAuthorization() async -> Bool {
        true
    }

    func isAuthorized() async -> Bool {
        true
    }

    func schedule(at _: Date, title _: String, body _: String, actionTitle _: String) async throws {}
    func cancel() async {}
}

struct LocalNotificationHydrationReminder: HydrationReminderScheduling {
    static let identifier = "hydration-reminder"
    static let categoryIdentifier = "HYDRATION"
    static let addActionIdentifier = "HYDRATION_ADD"

    /// The same iOS permission as the check-in reminder, asked the same way.
    func requestAuthorization() async -> Bool {
        await LocalNotificationCheckInReminder().requestAuthorization()
    }

    func isAuthorized() async -> Bool {
        await LocalNotificationCheckInReminder().isAuthorized()
    }

    func schedule(at date: Date, title: String, body: String, actionTitle: String) async throws {
        let center = UNUserNotificationCenter.current()
        Self.registerCategory(actionTitle: actionTitle) // the smallest quick-add size may have changed
        // A reminder still in Notification Center describes the old plan.
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        // An interval trigger needs a positive interval: a reminder that is due fires after a second.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(date.timeIntervalSinceNow, 1), repeats: false)
        try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }

    func cancel() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    /// The `HYDRATION` category with its add-water action, which runs in the background (no app launch to the
    /// foreground). Registered at every launch, since iOS keeps categories only while the app runs, and with each
    /// reminder. The app has no other category.
    static func registerCategory(actionTitle: String) {
        let add = UNNotificationAction(identifier: addActionIdentifier, title: actionTitle, options: [])
        let category = UNNotificationCategory(identifier: categoryIdentifier, actions: [add], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// The reminder's texts (spec §4), from the string catalog.
enum HydrationReminderCopy {
    /// "+ 250 ml": the smallest quick-add size.
    static func actionTitle(ml: Int) -> String {
        "+ \(ml) ml"
    }

    static func title(_ reason: HydrationReminder.Reason) -> String {
        switch reason {
        case .gap: String(localized: "Time for a drink")
        case .behind: String(localized: "You're behind on hydration")
        }
    }

    /// "No drink since 13:00 · 1,320 of 2,400 ml" or "1,100 ml so far — about 1,600 by now keeps you on track";
    /// amounts grouped by `locale` like the Hydration tile, the "about" amount to the nearest 50 ml, the time in
    /// `locale`'s hour cycle (13:00, or 01:00 PM in the US) and `calendar`'s time zone.
    static func body(
        _ reason: HydrationReminder.Reason, totalMl: Double, goalMl: Double, calendar: Calendar, locale: Locale,
    ) -> String {
        let total = number(totalMl, locale)
        switch reason {
        case let .gap(since):
            let sinceText = time(since, calendar: calendar, locale: locale)
            let goal = number(goalMl, locale)
            return String(localized: "No drink since \(sinceText) · \(total) of \(goal) ml", locale: locale)
        case let .behind(expectedMl):
            let expected = number((expectedMl / 50).rounded() * 50, locale)
            return String(localized: "\(total) ml so far — about \(expected) by now keeps you on track", locale: locale)
        }
    }

    private static func number(_ ml: Double, _ locale: Locale) -> String {
        ml.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// Two-digit hours in `locale`'s hour cycle: "07:00" where the day has 24 hours, "07:00 AM" in the US.
    private static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).locale(locale)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
