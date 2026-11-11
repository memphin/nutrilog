import Foundation

/// A calendar day in the user's local calendar, stored as "YYYY-MM-DD" (SPEC §8 `diary_entry.day`).
/// Independent of time zones once created, so a day logged in Zagreb stays the same day when travelling.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// A Gregorian calendar in `calendar`'s time zone. `LocalDay` always holds Gregorian year-month-day numbers,
    /// so every `Date` ⇄ `LocalDay` conversion goes through this, whatever the device calendar is (Buddhist,
    /// Japanese, Hebrew, …). Only the time zone of the passed calendar is honoured; a Gregorian calendar is used as-is.
    static func gregorian(_ calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian {
            return calendar
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// The day containing `date` in `calendar`'s time zone (default: current time zone). The day is always the
    /// Gregorian one, whatever calendar system `calendar` uses.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = Self.gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        year = c.year!
        month = c.month!
        day = c.day!
    }

    /// Parses "YYYY-MM-DD".
    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func today(calendar: Calendar = .current, now: Date = Date()) -> LocalDay {
        LocalDay(now, calendar: calendar)
    }

    /// "YYYY-MM-DD"
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String {
        isoString
    }

    /// Start of this day (00:00) in `calendar`'s time zone. Handles DST days correctly.
    public func startDate(calendar: Calendar = .current) -> Date {
        Self.gregorian(calendar).date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> LocalDay {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = utc.date(byAdding: .day, value: days, to: startDate(calendar: utc))!
        return LocalDay(date, calendar: utc)
    }

    public var previous: LocalDay {
        adding(days: -1)
    }

    public var next: LocalDay {
        adding(days: 1)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: LocalDay) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.dateComponents([.day], from: startDate(calendar: utc), to: other.startDate(calendar: utc)).day!
    }

    /// Calendar weekday, 1 = Sunday … 7 = Saturday (matches `profile.checkin_weekday`).
    public var weekday: Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.component(.weekday, from: startDate(calendar: utc))
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Codable as the plain "YYYY-MM-DD" string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = LocalDay(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid day \(string)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}
