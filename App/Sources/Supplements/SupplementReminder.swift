import Core
import Foundation
import Persistence
import UserNotifications

/// A planned supplement notification (Core `SupplementReminderPlanner.Reminder` with its texts).
struct SupplementNotification: Equatable, Sendable {
    var identifier: String
    var fireDate: Date
    var title: String
    var body: String
}

/// The supplement reminders: one pending local notification per slot and kind (due, follow-up, snoozed), all
/// replaced whenever the plan changes. Their "Taken" action logs the slot's doses in the background.
protocol SupplementReminderScheduling: Sendable {
    /// Asks for notification permission if needed; false when the user declined.
    func requestAuthorization() async -> Bool
    /// True when notifications are already allowed. Never asks: for background recomputes.
    func isAuthorized() async -> Bool
    /// Makes `notifications` the pending supplement reminders (others are removed) and removes delivered ones whose
    /// slot is no longer in `openSlots`.
    func replace(with notifications: [SupplementNotification], openSlots: Set<SupplementSlot>) async
}

/// Tests, previews: nothing is scheduled.
struct NoSupplementReminder: SupplementReminderScheduling {
    func requestAuthorization() async -> Bool {
        true
    }

    func isAuthorized() async -> Bool {
        true
    }

    func replace(with _: [SupplementNotification], openSlots _: Set<SupplementSlot>) async {}
}

/// "supplement:2026-11-09:480:due": the identifiers of the supplement notifications name their slot and kind, so a
/// response can be acted on without any stored state.
enum SupplementNotificationID {
    static let prefix = "supplement:"

    static func make(_ slot: SupplementSlot, _ kind: SupplementReminderPlanner.Kind) -> String {
        "\(prefix)\(slot.day.isoString):\(slot.minute):\(kind.rawValue)"
    }

    static func parse(_ identifier: String) -> (slot: SupplementSlot, kind: SupplementReminderPlanner.Kind)? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ":")
        guard parts.count == 3, let day = LocalDay(String(parts[0])), let minute = Int(parts[1]), (0 ..< 1440).contains(minute),
              let kind = SupplementReminderPlanner.Kind(rawValue: String(parts[2]))
        else { return nil }
        return (SupplementSlot(day: day, minute: minute), kind)
    }
}

struct LocalNotificationSupplementReminder: SupplementReminderScheduling {
    static let categoryIdentifier = "SUPPLEMENT"
    static let takenActionIdentifier = "SUPPLEMENT_TAKEN"
    static let snoozeActionIdentifier = "SUPPLEMENT_SNOOZE"

    /// The same iOS permission as the other reminders, asked the same way.
    func requestAuthorization() async -> Bool {
        await LocalNotificationCheckInReminder().requestAuthorization()
    }

    func isAuthorized() async -> Bool {
        await LocalNotificationCheckInReminder().isAuthorized()
    }

    func replace(with notifications: [SupplementNotification], openSlots: Set<SupplementSlot>) async {
        let center = UNUserNotificationCenter.current()
        let wanted = Set(notifications.map(\.identifier))
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(SupplementNotificationID.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { identifier in
            guard let parsed = SupplementNotificationID.parse(identifier) else { return false }
            return !openSlots.contains(parsed.slot)
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.threadIdentifier = "supplements"
            let interval = max(notification.fireDate.timeIntervalSinceNow, 1) // a due reminder fires after a second
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            // Adding with an identifier already pending replaces it (new texts, same time).
            try? await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
        }
    }

    /// The `SUPPLEMENT` category: "Taken" logs the doses in the background, "Snooze" reminds again later.
    static var category: UNNotificationCategory {
        let taken = UNNotificationAction(identifier: takenActionIdentifier, title: String(localized: "Taken"), options: [])
        let snooze = UNNotificationAction(
            identifier: snoozeActionIdentifier,
            title: String(localized: "Snooze \(SupplementReminderService.snoozeMinutes) min"),
            options: [],
        )
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [taken, snooze], intentIdentifiers: [], options: [])
    }
}

/// The reminder texts, from the string catalog.
enum SupplementReminderCopy {
    static func title(_ kind: SupplementReminderPlanner.Kind) -> String {
        switch kind {
        case .due, .snoozed: String(localized: "Time to take")
        case .followUp: String(localized: "Not taken yet")
        }
    }

    /// "Vitamin D3 · 2000 IU, Omega-3 · 2 caps", after "Due at 08:00: " for a follow-up.
    static func body(_ reminder: SupplementReminderPlanner.Reminder, calendar: Calendar, locale: Locale) -> String {
        let names = reminder.items.map { $0.dose.isEmpty ? $0.name : "\($0.name) · \($0.dose)" }
            .formatted(.list(type: .and).locale(locale))
        guard reminder.kind == .followUp else { return names }
        let time = SupplementFormat.time(reminder.slot.minute, calendar: calendar, locale: locale)
        return String(localized: "Due at \(time): \(names)", locale: locale)
    }
}

/// Times of day of the supplement schedules.
enum SupplementFormat {
    /// "08:00" (or "8:00 AM") for minutes after midnight, in `locale`'s hour cycle.
    static func time(_ minute: Int, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        style.timeZone = calendar.timeZone
        return date(minute, calendar: calendar).formatted(style)
    }

    /// The minute on a fixed day, for formatting and time pickers.
    static func date(
        _ minute: Int, on day: LocalDay = LocalDay(year: 2026, month: 1, day: 5)!, calendar: Calendar = .autoupdatingCurrent,
    ) -> Date {
        SupplementSlot(day: day, minute: minute).date(calendar: calendar)
    }

    /// Minutes after midnight of `date`.
    static func minute(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "08:00, 21:00 · Mon, Wed, Fri", "08:00 · every day" or "As needed".
    static func schedule(_ schedule: SupplementSchedule, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard !schedule.isAsNeeded else { return String(localized: "As needed") }
        let times = schedule.times.map { time($0, calendar: calendar) }.joined(separator: ", ")
        guard !schedule.isEveryDay else { return String(localized: "\(times) · every day") }
        let days = weekdayOrder(calendar).filter(schedule.weekdays.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }
        return "\(times) · \(days.joined(separator: ", "))"
    }

    /// Weekday numbers starting at the calendar's first weekday.
    static func weekdayOrder(_ calendar: Calendar = .autoupdatingCurrent) -> [Int] {
        (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}
