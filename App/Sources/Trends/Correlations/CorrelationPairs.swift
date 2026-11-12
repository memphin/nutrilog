import Core
import Foundation

/// One point of a correlation: a day (x on `day`, y on `day` or the day after) or a week (`day` is its first day).
struct CorrelationPair: Identifiable, Hashable {
    var day: LocalDay
    var x: Double
    var y: Double

    var id: LocalDay {
        day
    }
}

/// Turns `DayStats` into pairs for a `CorrelationSpec` (FR-53). Pure, so lags, weeks and left-out days are unit-tested.
///
/// - Daily: x on day D and y on D (same day) or D + 1 (next day), both inside the range, both with a value.
/// - Weekly: whole weeks of the range, starting on the user's first weekday (as `ChartBuilder.weekly`). A side's value is
///   the mean of the week's days that have one, and needs `minimumDaysPerWeek` of them. Weight-trend change is the trend
///   on the week's last day minus the trend on the day before the week (seven days, so kg/week, as the weekly report),
///   and needs both.
/// - Intake counts only fully logged days (`DayStats.isLogged`).
enum CorrelationPairBuilder {
    /// Days with a value a week needs before its average counts.
    static let minimumDaysPerWeek = 4

    /// - Parameter days: the days to look at; the caller ends them before today (`CorrelationPeriod.days(before:)`).
    ///   For weekly pairs `stats` should also hold the day before `days`, for the trend before the first week.
    static func pairs(
        _ spec: CorrelationSpec, stats: [DayStats], in days: ClosedRange<LocalDay>, unit: EnergyUnit, firstWeekday: Int,
    ) -> [CorrelationPair] {
        let spec = spec.normalized
        let byDay = Dictionary(stats.map { ($0.day, $0) }) { first, _ in first }
        return switch spec.granularity {
        case .daily: daily(spec, byDay: byDay, in: days, unit: unit)
        case .weekly: weekly(spec, byDay: byDay, in: days, unit: unit, firstWeekday: firstWeekday)
        }
    }

    private static func daily(
        _ spec: CorrelationSpec, byDay: [LocalDay: DayStats], in days: ClosedRange<LocalDay>, unit: EnergyUnit,
    ) -> [CorrelationPair] {
        var result: [CorrelationPair] = []
        var day = days.lowerBound
        while day <= days.upperBound {
            let partner = day.adding(days: spec.lag.days)
            if partner <= days.upperBound,
               let x = byDay[day].flatMap({ spec.x.dailyValue($0, unit: unit) }),
               let y = byDay[partner].flatMap({ spec.y.dailyValue($0, unit: unit) })
            {
                result.append(CorrelationPair(day: day, x: x, y: y))
            }
            day = day.next
        }
        return result
    }

    private static func weekly(
        _ spec: CorrelationSpec, byDay: [LocalDay: DayStats], in days: ClosedRange<LocalDay>, unit: EnergyUnit, firstWeekday: Int,
    ) -> [CorrelationPair] {
        var week = days.lowerBound.weekStart(firstWeekday: firstWeekday)
        if week < days.lowerBound {
            week = week.adding(days: 7)
        }
        var result: [CorrelationPair] = []
        while week.adding(days: 6) <= days.upperBound {
            if let x = weeklyValue(spec.x, week: week, byDay: byDay, unit: unit),
               let y = weeklyValue(spec.y, week: week, byDay: byDay, unit: unit)
            {
                result.append(CorrelationPair(day: week, x: x, y: y))
            }
            week = week.adding(days: 7)
        }
        return result
    }

    private static func weeklyValue(_ metric: CorrelationMetric, week: LocalDay, byDay: [LocalDay: DayStats], unit: EnergyUnit) -> Double? {
        if metric == .weightTrendChange {
            guard let end = byDay[week.adding(days: 6)]?.trendKg, let start = byDay[week.previous]?.trendKg else { return nil }
            return end - start
        }
        let values = (0 ..< 7).compactMap { byDay[week.adding(days: $0)].flatMap { metric.dailyValue($0, unit: unit) } }
        guard values.count >= minimumDaysPerWeek else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// A spec's pairs over a period and what they show: the one code path behind the cards and "Compare any two".
struct CorrelationAnalysis: Hashable {
    /// Normalized (`CorrelationSpec.normalized`).
    var spec: CorrelationSpec
    var period: CorrelationPeriod
    var unit: EnergyUnit
    var pairs: [CorrelationPair]
    var result: CorrelationResult

    var isWeekly: Bool {
        spec.granularity == .weekly
    }

    /// The days to load for `period`: its days and the one before (the trend before the first week).
    static func loadRange(_ period: CorrelationPeriod, today: LocalDay) -> ClosedRange<LocalDay> {
        let days = period.days(before: today)
        return days.lowerBound.previous ... days.upperBound
    }

    static func make(
        _ spec: CorrelationSpec, period: CorrelationPeriod, stats: [DayStats], today: LocalDay, unit: EnergyUnit, firstWeekday: Int,
    ) -> CorrelationAnalysis {
        let spec = spec.normalized
        let pairs = CorrelationPairBuilder.pairs(
            spec, stats: stats, in: period.days(before: today), unit: unit, firstWeekday: firstWeekday,
        )
        return CorrelationAnalysis(
            spec: spec, period: period, unit: unit, pairs: pairs,
            result: CorrelationResult(points: pairs.map { CorrelationPoint(x: $0.x, y: $0.y) }, minimumCount: spec.minimumPairs),
        )
    }
}
