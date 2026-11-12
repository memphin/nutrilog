import Core
import Foundation
import Persistence

/// What can be charted (FR-51, backlog #38).
enum ChartMetric: String, CaseIterable, Identifiable {
    case weight, bodyFat, energy, macros, steps, sleep, restingHeartRate, hrv, water, totalEnergy

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .weight: String(localized: "Weight")
        case .bodyFat: String(localized: "Body fat")
        case .energy: String(localized: "Calories vs target")
        case .macros: String(localized: "Macros")
        case .steps: String(localized: "Steps")
        case .sleep: String(localized: "Sleep")
        case .restingHeartRate: String(localized: "Resting heart rate")
        case .hrv: String(localized: "HRV")
        case .water: String(localized: "Hydration")
        case .totalEnergy: String(localized: "Total energy")
        }
    }

    var systemImage: String {
        switch self {
        case .weight: "scalemass"
        case .bodyFat: "percent"
        case .energy: "flame"
        case .macros: "chart.bar.xaxis"
        case .steps: "figure.walk"
        case .sleep: "bed.double"
        case .restingHeartRate: "heart"
        case .hrv: "waveform.path.ecg"
        case .water: "drop"
        case .totalEnergy: "flame.circle"
        }
    }

    /// Bars for amounts per day; lines for measurements.
    var isBar: Bool {
        switch self {
        case .energy, .macros, .steps, .sleep, .water, .totalEnergy: true
        case .weight, .bodyFat, .restingHeartRate, .hrv: false
        }
    }

    /// The chart a dashboard tile opens; nil for caffeine, whose detail draws its own curve.
    init?(tile: DashboardTile) {
        switch tile {
        case .energy: self = .energy
        case .water: self = .water
        case .sleep: self = .sleep
        case .weight: self = .weight
        case .bodyFat: self = .bodyFat
        case .steps: self = .steps
        case .totalEnergy: self = .totalEnergy
        case .restingHeartRate: self = .restingHeartRate
        case .hrv: self = .hrv
        case .caffeine: return nil
        }
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", quarter = "3M", year = "1Y"

    var id: String {
        rawValue
    }

    /// The segment label ("1W", …); the language may abbreviate differently.
    var title: String {
        switch self {
        case .week: String(localized: "1W", comment: "Chart range: one week")
        case .month: String(localized: "1M", comment: "Chart range: one month")
        case .quarter: String(localized: "3M", comment: "Chart range: three months")
        case .year: String(localized: "1Y", comment: "Chart range: one year")
        }
    }

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    var spokenTitle: String {
        switch self {
        case .week: String(localized: "last 7 days")
        case .month: String(localized: "last 30 days")
        case .quarter: String(localized: "last 3 months")
        case .year: String(localized: "last year")
        }
    }

    /// The days shown when the range ends on `today`.
    func days(endingOn today: LocalDay) -> ClosedRange<LocalDay> {
        today.adding(days: -(days - 1)) ... today
    }
}

/// One mark of a chart: a day, or a week for the long ranges of bar charts.
struct ChartPoint: Identifiable, Equatable {
    /// The day, or the first day of the bucket.
    var day: LocalDay
    /// Days covered (1 or 7).
    var spanDays: Int
    /// The main value (already in display units); nil when the day has none.
    var value: Double?
    /// Weight: the trend. Calories: the target.
    var reference: Double?
    /// Macros only, in grams.
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    /// Total energy only: the two parts of `value` (display units), drawn as one stacked bar (#66).
    var resting: Double?
    var active: Double?

    var id: LocalDay {
        day
    }
}

struct ChartSeries: Equatable {
    var metric: ChartMetric
    var range: ChartRange
    var points: [ChartPoint]
    /// Mean of the daily values in the range (not of the buckets), so it equals the weekly report's averages.
    var average: Double?
    /// Days of the range that have a value.
    var daysWithData: Int
    var unitLabel: String
    /// Days per mark: 1, or 7 when bars are grouped by week.
    var bucketDays: Int

    var isEmpty: Bool {
        daysWithData == 0
    }
}

/// Which days count for intake averages.
enum IntakeStats {
    /// `stats` with today's intake removed while the day is still being logged (not marked as fully logged).
    static func finished(_ stats: [DayStats], today: LocalDay?) -> [DayStats] {
        stats.map { day in
            guard day.day == today, !day.isComplete else { return day }
            var open = day
            open.intake = nil
            return open
        }
    }
}

/// Turns `DayStats` into chart series. Pure, so the numbers are unit-tested against the weekly report.
enum ChartBuilder {
    /// The daily value of `metric` in display units.
    static func value(_ metric: ChartMetric, _ day: DayStats, unit: EnergyUnit) -> Double? {
        switch metric {
        case .weight: day.weightKg
        case .bodyFat: day.bodyFatPct
        case .energy, .macros: day.kcal.map(unit.display)
        case .steps: day.steps.map(Double.init)
        case .sleep: day.sleepMin.map { Double($0) / 60 }
        case .restingHeartRate: day.restingHR
        case .hrv: day.hrvMs
        case .water: day.waterMl
        case .totalEnergy: day.totalBurnedKcal.map(unit.display)
        }
    }

    static func unitLabel(_ metric: ChartMetric, unit: EnergyUnit) -> String {
        switch metric {
        case .weight: "kg"
        case .bodyFat: "%"
        case .energy, .totalEnergy: unit.symbol
        case .macros: "g"
        case .steps: String(localized: "steps", comment: "Unit after a number of steps (\"8,412 steps\")")
        case .sleep: "h"
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .water: "ml"
        }
    }

    /// - Parameters:
    ///   - stats: the days of the range, oldest first.
    ///   - today: when given, today's intake is drawn but left out of the average of the intake charts unless the
    ///     day is marked as fully logged — a half-logged day would pull the average down (the weekly report does
    ///     the same, see `IntakeStats.finished`). Today's steps, water and total energy are drawn but never averaged:
    ///     they keep growing until the day is over (as in `WeeklyReport`).
    static func series(
        _ metric: ChartMetric,
        range: ChartRange,
        stats: [DayStats],
        unit: EnergyUnit,
        firstWeekday: Int = 2,
        today: LocalDay? = nil,
    ) -> ChartSeries {
        let daily = stats.map { day -> ChartPoint in
            var point = ChartPoint(day: day.day, spanDays: 1, value: value(metric, day, unit: unit))
            switch metric {
            case .weight:
                point.reference = day.trendKg
            case .energy:
                point.reference = day.targetKcal.map(unit.display)
            case .macros:
                point.proteinG = day.intake?.proteinG
                point.carbsG = day.intake?.carbsG
                point.fatG = day.intake?.fatG
            case .totalEnergy:
                // Only for a day with a total, so the two parts always add up to the bar.
                if point.value != nil {
                    point.resting = day.basalKcal.map(unit.display)
                    point.active = day.activeKcal.map(unit.display)
                }
            default:
                break
            }
            return point
        }
        let counted: [DayStats] = switch metric {
        case .energy, .macros: IntakeStats.finished(stats, today: today)
        // Totals that keep growing through the day: today is always unfinished (the weekly report does the same).
        case .steps, .water, .totalEnergy: stats.filter { $0.day != today }
        // Measurements stand on their own, and last night's sleep is over by morning.
        case .weight, .bodyFat, .sleep, .restingHeartRate, .hrv: stats
        }
        let values = counted.compactMap { value(metric, $0, unit: unit) }
        let groupsByWeek = metric.isBar && range.days > 31
        return ChartSeries(
            metric: metric, range: range,
            points: groupsByWeek ? weekly(daily, firstWeekday: firstWeekday) : daily,
            average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
            daysWithData: values.count,
            unitLabel: unitLabel(metric, unit: unit),
            bucketDays: groupsByWeek ? 7 : 1,
        )
    }

    /// Weekly means of the days that have a value.
    static func weekly(_ daily: [ChartPoint], firstWeekday: Int) -> [ChartPoint] {
        var order: [LocalDay] = []
        var buckets: [LocalDay: [ChartPoint]] = [:]
        for point in daily {
            let week = point.day.weekStart(firstWeekday: firstWeekday)
            if buckets[week] == nil {
                order.append(week)
            }
            buckets[week, default: []].append(point)
        }
        return order.map { week in
            let points = buckets[week] ?? []
            return ChartPoint(
                day: week, spanDays: 7,
                value: Stats.mean(points.map(\.value)), reference: Stats.mean(points.map(\.reference)),
                proteinG: Stats.mean(points.map(\.proteinG)), carbsG: Stats.mean(points.map(\.carbsG)),
                fatG: Stats.mean(points.map(\.fatG)),
                resting: Stats.mean(points.map(\.resting)), active: Stats.mean(points.map(\.active)),
            )
        }
    }

    /// Each day's hydration goal (`HydrationGoalResolver`); `trendsKg` from `HydrationGoalResolver.trendsKg(in:environment:)`,
    /// `training` (the training days of `days`) from `HydrationGoalResolver.trainingDays(in:environment:)`.
    static func hydrationGoals(
        in days: ClosedRange<LocalDay>, profile: Profile, trendsKg: [LocalDay: Double], training: TrainingDays,
    ) -> [LocalDay: Double] {
        var goals: [LocalDay: Double] = [:]
        var day = days.lowerBound
        while day <= days.upperBound {
            goals[day] = HydrationGoalResolver.goalMl(on: day, profile: profile, trendKg: trendsKg[day], training: training)
            day = day.next
        }
        return goals
    }

    /// The goal of a bar: its day's, or for a weekly bar the mean of its days' goals; nil when none is known.
    static func goal(of point: ChartPoint, in goals: [LocalDay: Double]) -> Double? {
        Stats.mean((0 ..< point.spanDays).map { goals[point.day.adding(days: $0)] })
    }

    /// "8,412 steps", "7.4 h", "81.3 kg".
    static func format(_ value: Double, _ metric: ChartMetric, unit: EnergyUnit) -> String {
        let digits = switch metric {
        case .weight, .bodyFat, .sleep: 1
        default: 0
        }
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unitLabel(metric, unit: unit))"
    }

    /// A spoken summary of the chart for VoiceOver and the caption under it.
    static func summary(_ series: ChartSeries, unit: EnergyUnit) -> String {
        let name = series.metric.title
        let range = series.range.spokenTitle
        guard let average = series.average else { return String(localized: "\(name), \(range): no data.") }
        let values = series.points.compactMap(\.value)
        let mean = format(average, series.metric, unit: unit)
        // Whole sentences, so a language can reorder them.
        var sentences: [String]
        if let low = values.min(), let high = values.max(), values.count > 1 {
            let from = format(low, series.metric, unit: unit), to = format(high, series.metric, unit: unit)
            sentences = [series.bucketDays == 7
                ? String(localized: "\(name), \(range): average \(mean), from \(from) to \(to) (weekly averages).")
                : String(localized: "\(name), \(range): average \(mean), from \(from) to \(to).")]
        } else {
            sentences = [String(localized: "\(name), \(range): average \(mean).")]
        }
        sentences.append(String(localized: "\(series.daysWithData) of \(series.range.days) days have data."))
        let trend = series.points.compactMap(\.reference)
        if series.metric == .weight, let first = trend.first, let last = trend.last {
            sentences.append(String(localized: "Trend \(DashboardFormat.kgChange(last - first)) over the period."))
        }
        return sentences.joined(separator: " ")
    }
}
