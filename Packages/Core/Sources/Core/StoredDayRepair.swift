import Foundation

/// Recovers the Gregorian day of a stored "YYYY-MM-DD" written before `LocalDay` always used the Gregorian calendar.
///
/// Before `LocalDay` converted through `LocalDay.gregorian(_:)`, `LocalDay(date)` read year, month and day from the device calendar, so on an iPhone set to, say, the
/// Buddhist calendar Gregorian 2026-11-11 was stored as "2569-11-11" (Japanese: "0008-11-11", Persian: "1405-08-20").
/// This maps such a stored triple back to the Gregorian day it was, and returns nil whenever that is not certain —
/// the caller then leaves the value alone. Pure: the device calendar and the plausible range are passed in.
///
/// Decision rules, in order:
/// 1. A year inside `scope.gregorianYears` is a Gregorian day already and is never touched (nil).
/// 2. Device calendar Chinese, Dangi, Vietnamese or any other calendar not listed below (cyclic years or unknown year
///    semantics): nil — rows written under it can't be told apart from other calendars' years.
/// 3. Device calendar non-Gregorian and supported (`deviceCalendars`): if the triple is a valid date in it that falls in
///    `scope.plausibleDays`, that is the answer (all Japanese eras are tried; more than one hit is ambiguous → nil).
/// 4. Otherwise (device Gregorian now — the user may have switched — or the triple doesn't fit the device calendar):
///    every calendar in `inferredCalendars` outside the device calendar's family is tried; exactly one distinct
///    plausible Gregorian day is the answer, none or several → nil.
///
/// "Valid date" means the triple round-trips through Foundation's `Calendar` unchanged (so leap days, Hebrew leap
/// months and 31-day Persian months are honoured, and "1405-07-31" Persian is rejected rather than rolled over).
public enum StoredDayRepair {
    /// Where a stored day may plausibly lie.
    public struct Scope: Hashable, Sendable {
        /// Years that are taken as Gregorian as they are, whatever the device calendar.
        public var gregorianYears: ClosedRange<Int>
        /// A converted day must fall in here to be accepted.
        public var plausibleDays: ClosedRange<LocalDay>

        public init(gregorianYears: ClosedRange<Int>, plausibleDays: ClosedRange<LocalDay>) {
            self.gregorianYears = gregorianYears
            self.plausibleDays = plausibleDays
        }

        /// Diary, water, plan, note, metrics, target and check-in days. 2000…2200 is Gregorian (the app's history
        /// starts at 2000-01-01, `StatsLoader.historyStart`); a converted day must lie in 2020-01-01 … today + 400 days
        /// (plans and targets can be ahead of today). That makes the inferred year ranges Buddhist 2563…, Republic of
        /// China 109…, Japanese Reiwa 2…, Persian 1398…, Hebrew 5780…, Umm al-Qura 1441… up to about a year from now.
        public static func activity(today: LocalDay) -> Scope {
            Scope(gregorianYears: 2000 ... 2200, plausibleDays: LocalDay(year: 2020, month: 1, day: 1)! ... today.adding(days: 400))
        }

        /// `profile.birth_date`: 1900…2200 is Gregorian (a real birth year is never touched), a converted day must lie
        /// in 1900-01-01 … today. Japanese birth dates are ambiguous (Shōwa / Heisei / Reiwa) and are left alone.
        public static func birthDate(today: LocalDay) -> Scope {
            Scope(gregorianYears: 1900 ... 2200, plausibleDays: LocalDay(year: 1900, month: 1, day: 1)! ... today)
        }
    }

    /// Calendars the old `LocalDay` could have written that are converted when the device uses them now.
    /// Ethiopic Amete Alem is left out: Foundation converts its years differently between OS versions (a day stored
    /// as 7519-03-02 round-trips on one and not on another), so its days are never repaired rather than repaired
    /// on some devices only.
    public static let deviceCalendars: Set<Calendar.Identifier> = [
        .buddhist, .japanese, .republicOfChina, .persian, .hebrew, .indian, .coptic, .ethiopicAmeteMihret,
        .islamic, .islamicCivil, .islamicTabular, .islamicUmmAlQura,
    ]

    /// Calendars inferred from the year alone when the device calendar doesn't say (rule 4). The Islamic variants
    /// differ by a day or so, so only Umm al-Qura (Saudi Arabia's, Foundation's usual "Islamic") is inferred.
    public static let inferredCalendars: [Calendar.Identifier] = [
        .buddhist, .republicOfChina, .japanese, .persian, .hebrew, .islamicUmmAlQura,
    ]

    /// The Gregorian day a stored triple really was, or nil when it is Gregorian already or can't be told for certain.
    public static func repairedDay(
        year: Int, month: Int, day: Int, deviceCalendar: Calendar.Identifier, scope: Scope,
    ) -> LocalDay? {
        guard !scope.gregorianYears.contains(year), (1 ... 13).contains(month), (1 ... 31).contains(day) else { return nil }
        let device = deviceCalendar == .iso8601 ? .gregorian : deviceCalendar
        if device != .gregorian {
            guard deviceCalendars.contains(device) else { return nil }
            let hits = candidates(year: year, month: month, day: day, in: device, scope: scope)
            if hits.count == 1 {
                return hits.first
            }
            if hits.count > 1 {
                return nil
            }
        }
        var hits = Set<LocalDay>()
        for calendar in inferredCalendars where family(calendar) != family(device) {
            hits.formUnion(candidates(year: year, month: month, day: day, in: calendar, scope: scope))
        }
        return hits.count == 1 ? hits.first : nil
    }

    /// `repairedDay` for a stored "YYYY-MM-DD" (four, two and two ASCII digits — the old `isoString`, which may not
    /// parse as a Gregorian `LocalDay`, e.g. "2571-02-29"). Nil for anything else.
    public static func repairedDay(_ stored: String, deviceCalendar: Calendar.Identifier, scope: Scope) -> LocalDay? {
        guard let (year, month, day) = triple(stored) else { return nil }
        return repairedDay(year: year, month: month, day: day, deviceCalendar: deviceCalendar, scope: scope)
    }

    /// Rewrites every JSON string value that is exactly a repairable "YYYY-MM-DD" (e.g. the days inside a stored
    /// `TDEEEstimate`), leaving every other byte as it is. Nil when nothing changed.
    public static func repairingDays(inJSON json: String, deviceCalendar: Calendar.Identifier, scope: Scope) -> String? {
        let bytes = Array(json.utf8)
        let length = 12 // "YYYY-MM-DD" with its quotes
        guard bytes.count >= length else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\""), index + length <= bytes.count, bytes[index + length - 1] == UInt8(ascii: "\""),
               index == 0 || bytes[index - 1] != UInt8(ascii: "\\"),
               let stored = String(bytes: bytes[(index + 1) ..< (index + length - 1)], encoding: .utf8),
               let repaired = repairedDay(stored, deviceCalendar: deviceCalendar, scope: scope),
               repaired.isoString != stored
            {
                output.append(UInt8(ascii: "\""))
                output.append(contentsOf: Array(repaired.isoString.utf8))
                output.append(UInt8(ascii: "\""))
                index += length
                changed = true
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return changed ? String(decoding: output, as: UTF8.self) : nil
    }

    // MARK: Helpers

    static func triple(_ stored: String) -> (Int, Int, Int)? {
        let utf8 = Array(stored.utf8)
        guard utf8.count == 10, utf8[4] == UInt8(ascii: "-"), utf8[7] == UInt8(ascii: "-") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in utf8[range] {
                guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0 ..< 4), let month = number(5 ..< 7), let day = number(8 ..< 10) else { return nil }
        return (year, month, day)
    }

    /// Calendars whose year numbers mean the same thing: if the device's one didn't fit, its siblings aren't tried.
    static func family(_ calendar: Calendar.Identifier) -> String {
        switch calendar {
        case .islamic, .islamicCivil, .islamicTabular, .islamicUmmAlQura: "islamic"
        case .ethiopicAmeteMihret, .ethiopicAmeteAlem: "ethiopic"
        default: "\(calendar)"
        }
    }

    /// The plausible Gregorian days the triple is in `identifier` (one per era for the Japanese calendar).
    static func candidates(year: Int, month: Int, day: Int, in identifier: Calendar.Identifier, scope: Scope) -> Set<LocalDay> {
        let utc = TimeZone(secondsFromGMT: 0)!
        var source = Calendar(identifier: identifier)
        source.timeZone = utc
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        var eras: [Int?] = [nil]
        if identifier == .japanese, let latest = scope.plausibleDays.upperBound.noonUTC(gregorian) {
            // The old code stored the year without its era. Try the current era and the ones before it.
            let current = source.component(.era, from: latest)
            eras = (max(0, current - 4) ... current).map(Optional.some)
        }
        var result = Set<LocalDay>()
        for era in eras {
            guard let date = source.date(from: DateComponents(era: era, year: year, month: month, day: day, hour: 12)) else { continue }
            let back = source.dateComponents([.era, .year, .month, .day], from: date)
            guard back.year == year, back.month == month, back.day == day, era == nil || back.era == era else { continue }
            let g = gregorian.dateComponents([.year, .month, .day], from: date)
            guard let y = g.year, let m = g.month, let d = g.day, let converted = LocalDay(year: y, month: m, day: d),
                  scope.plausibleDays.contains(converted) else { continue }
            result.insert(converted)
        }
        return result
    }
}

private extension LocalDay {
    func noonUTC(_ gregorian: Calendar) -> Date? {
        gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}
