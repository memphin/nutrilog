import Foundation

/// Days in a row a daily goal was reached, counted back from today. Today still running does not break it: when
/// today is not reached (yet), the streak is the one ending yesterday — unless today is already final (see
/// `todayIsFinal`), as last night's sleep is once it is recorded.
public struct Streak: Equatable, Sendable {
    public var days: Int
    /// Today is one of the days (the goal is already reached today).
    public var includesToday: Bool
    /// Counting stopped at the limit; the real streak may be longer.
    public var isAtLimit: Bool

    public init(days: Int, includesToday: Bool, isAtLimit: Bool) {
        self.days = days
        self.includesToday = includesToday
        self.isAtLimit = isAtLimit
    }

    public static let none = Streak(days: 0, includesToday: false, isAtLimit: false)

    /// - Parameters:
    ///   - maxDays: the most days looked at (the history that is loaded), today included.
    ///   - todayIsFinal: today's value can no longer change (e.g. last night's sleep, recorded in the morning), so a
    ///     today that misses the goal ends the streak (no streak) instead of leaving it open until tomorrow.
    ///   - reached: whether the goal was reached on a day.
    public static func current(
        today: LocalDay, maxDays: Int, todayIsFinal: Bool = false, reached: (LocalDay) -> Bool,
    ) -> Streak {
        guard maxDays > 0 else { return .none }
        let includesToday = reached(today)
        if todayIsFinal, !includesToday {
            return .none
        }
        var day = includesToday ? today : today.previous
        // Without today, yesterday is the first of at most maxDays - 1 days left in the window.
        let limit = includesToday ? maxDays : maxDays - 1
        var days = 0
        while days < limit, reached(day) {
            days += 1
            day = day.previous
        }
        return Streak(days: days, includesToday: includesToday, isAtLimit: days > 0 && days == limit)
    }
}
