import Foundation

/// How a day's energy compares with its target (FR-50, backlog #37).
public enum Adherence: String, Sendable, CaseIterable {
    /// Within ±5 % of the target.
    case onTarget
    /// Within ±15 %.
    case near
    /// Further off.
    case off
    /// Logged, but no target was in effect that day.
    case noTarget
    /// Nothing logged.
    case notLogged

    public static let onTargetFraction = 0.05
    public static let nearFraction = 0.15

    public static func band(kcal: Double?, targetKcal: Double?) -> Adherence {
        guard let kcal else { return .notLogged }
        guard let targetKcal, targetKcal > 0 else { return .noTarget }
        let deviation = abs(kcal - targetKcal) / targetKcal
        // A hair of tolerance so that exactly 5 % / 15 % (in floating point) stays in the better band.
        if deviation <= onTargetFraction + 1e-9 {
            return .onTarget
        }
        return deviation <= nearFraction + 1e-9 ? .near : .off
    }

    public var title: String {
        switch self {
        case .onTarget: String(localized: "On target (within 5%)", bundle: .module)
        case .near: String(localized: "Close (within 15%)", bundle: .module)
        case .off: String(localized: "Off target", bundle: .module)
        case .noTarget: String(localized: "Logged, no target", bundle: .module)
        case .notLogged: String(localized: "Not logged", bundle: .module)
        }
    }
}

/// Resolves which of several dated values was in effect on a day — e.g. calorie targets by `effective_from`.
public struct EffectiveTimeline<Value: Sendable>: Sendable {
    private let entries: [(from: LocalDay, value: Value)]

    /// `entries` in any order; with two entries on the same day the later one in the array wins.
    public init(_ entries: [(from: LocalDay, value: Value)]) {
        var byDay: [LocalDay: Value] = [:]
        for entry in entries {
            byDay[entry.from] = entry.value
        }
        self.entries = byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The value with the latest start on or before `day`; nil before the first one.
    public func value(on day: LocalDay) -> Value? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].from <= day {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? entries[low - 1].value : nil
    }
}

public extension LocalDay {
    /// The first day of the week containing this day, for weeks starting on `firstWeekday`
    /// (1 = Sunday … 7 = Saturday, as `Calendar.firstWeekday`).
    func weekStart(firstWeekday: Int = 2) -> LocalDay {
        adding(days: -((weekday - firstWeekday + 7) % 7))
    }

    /// The first day of this day's month.
    var monthStart: LocalDay {
        LocalDay(year: year, month: month, day: 1) ?? self
    }

    /// The first day of the month `months` away (negative = earlier).
    func addingMonths(_ months: Int) -> LocalDay {
        let index = year * 12 + (month - 1) + months
        return LocalDay(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1, day: 1) ?? self
    }

    /// Number of days in this day's month.
    var daysInMonth: Int {
        monthStart.days(until: addingMonths(1))
    }
}
