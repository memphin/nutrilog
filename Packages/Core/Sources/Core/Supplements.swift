import Foundation

/// When a supplement or medication is taken: at fixed times of day, every day or on some weekdays; or only as
/// needed (no times), logged by hand and never reminded.
public struct SupplementSchedule: Hashable, Sendable, Codable {
    /// Minutes after midnight (0 … 1439), sorted, no duplicates; empty = as needed.
    public var times: [Int] {
        didSet { times = Self.valid(times) }
    }

    /// Calendar weekdays, 1 = Sunday … 7 = Saturday (as `LocalDay.weekday`); empty = every day.
    public var weekdays: Set<Int> {
        didSet { weekdays = weekdays.filter { (1 ... 7).contains($0) } }
    }

    public init(times: [Int], weekdays: Set<Int> = []) {
        self.times = Self.valid(times)
        self.weekdays = weekdays.filter { (1 ... 7).contains($0) }
    }

    public static let asNeeded = SupplementSchedule(times: [])

    public var isAsNeeded: Bool {
        times.isEmpty
    }

    public var isEveryDay: Bool {
        weekdays.isEmpty || weekdays.count == 7
    }

    /// The times of the doses due on `day`: all of them on a scheduled weekday, none otherwise.
    public func times(on day: LocalDay) -> [Int] {
        isEveryDay || weekdays.contains(day.weekday) ? times : []
    }

    private static func valid(_ times: [Int]) -> [Int] {
        Array(Set(times.filter { (0 ..< 1440).contains($0) })).sorted()
    }
}

/// A time a dose is due: a day and the minute after its midnight.
public struct SupplementSlot: Hashable, Comparable, Sendable, Codable {
    public var day: LocalDay
    public var minute: Int

    public init(day: LocalDay, minute: Int) {
        self.day = day
        self.minute = minute
    }

    /// The moment of the slot in `calendar`'s time zone. A time skipped by a daylight-saving jump moves forward.
    public func date(calendar: Calendar) -> Date {
        let gregorian = LocalDay.gregorian(calendar)
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: minute / 60, minute: minute % 60)
        return gregorian.date(from: components) ?? day.startDate(calendar: calendar).addingTimeInterval(Double(minute) * 60)
    }

    public static func < (lhs: SupplementSlot, rhs: SupplementSlot) -> Bool {
        (lhs.day, lhs.minute) < (rhs.day, rhs.minute)
    }
}

/// One scheduled dose: a supplement at a slot.
public struct SupplementDoseKey: Hashable, Sendable {
    public var supplementID: String
    public var slot: SupplementSlot

    public init(supplementID: String, slot: SupplementSlot) {
        self.supplementID = supplementID
        self.slot = slot
    }
}

/// Plans the supplement reminders: one notification per slot (doses due at the same time share it) for the doses of
/// the next days that are neither taken nor skipped, plus one follow-up per slot if the doses are still open a while
/// after. A slot the user snoozed gets one reminder at the snooze time instead.
public enum SupplementReminderPlanner {
    /// A supplement that is reminded of: active, with reminders on and a schedule.
    public struct Item: Hashable, Sendable {
        public var id: String
        public var name: String
        public var dose: String
        public var schedule: SupplementSchedule
        /// The first day it is due (the day it was added): earlier days have no doses.
        public var startDay: LocalDay

        public init(id: String, name: String, dose: String, schedule: SupplementSchedule, startDay: LocalDay) {
            self.id = id
            self.name = name
            self.dose = dose
            self.schedule = schedule
            self.startDay = startDay
        }
    }

    public enum Kind: String, Hashable, Sendable {
        /// At the time the doses are due.
        case due
        /// ``followUpMinutes`` later, when the doses are still open.
        case followUp
        /// At the time the user snoozed the slot to.
        case snoozed
    }

    public struct Reminder: Hashable, Sendable {
        public var slot: SupplementSlot
        public var kind: Kind
        public var fireDate: Date
        /// The open doses of the slot, in the order of the items.
        public var items: [Item]
    }

    /// How long after a dose is due the follow-up comes.
    public static let followUpMinutes = 60
    /// How many days ahead are planned (today included). Reminders run out when the app isn't opened for that long.
    public static let horizonDays = 7
    /// iOS keeps 64 pending notifications per app; a few are left for the other reminders.
    public static let limit = 60

    /// The reminders after `now`, earliest first, at most `limit`. `handled` holds the doses taken or skipped;
    /// `snoozed` the slots the user snoozed and until when.
    public static func plan(
        items: [Item],
        handled: Set<SupplementDoseKey>,
        snoozed: [SupplementSlot: Date] = [:],
        now: Date,
        calendar: Calendar,
        horizonDays: Int = horizonDays,
        followUpMinutes: Int = followUpMinutes,
        limit: Int = limit,
    ) -> [Reminder] {
        let today = LocalDay(now, calendar: calendar)
        var open: [SupplementSlot: [Item]] = [:]
        for offset in 0 ..< max(horizonDays, 0) {
            let day = today.adding(days: offset)
            for item in items where day >= item.startDay {
                for minute in item.schedule.times(on: day) {
                    let slot = SupplementSlot(day: day, minute: minute)
                    guard !handled.contains(SupplementDoseKey(supplementID: item.id, slot: slot)) else { continue }
                    open[slot, default: []].append(item)
                }
            }
        }
        var reminders: [Reminder] = []
        for (slot, slotItems) in open {
            if let until = snoozed[slot], until > now {
                reminders.append(Reminder(slot: slot, kind: .snoozed, fireDate: until, items: slotItems))
                continue
            }
            let due = slot.date(calendar: calendar)
            if due > now {
                reminders.append(Reminder(slot: slot, kind: .due, fireDate: due, items: slotItems))
            }
            let followUp = due.addingTimeInterval(Double(followUpMinutes) * 60)
            if followUpMinutes > 0, followUp > now {
                reminders.append(Reminder(slot: slot, kind: .followUp, fireDate: followUp, items: slotItems))
            }
        }
        reminders.sort { ($0.fireDate, $0.slot, $0.kind.rawValue) < ($1.fireDate, $1.slot, $1.kind.rawValue) }
        return Array(reminders.prefix(max(limit, 0)))
    }
}
