import Core
import Foundation
import Persistence

/// Builds `DayStats` — the one per-day series behind the charts, the history calendar, the weekly report and the
/// adaptive TDEE estimate — so every screen shows the same numbers (backlog #38, #39).
enum StatsBuilder {
    /// One `DayStats` per day of `range`, oldest first.
    ///
    /// - Parameters:
    ///   - summaries: diary rows of the range (`DiaryRepository.daySummaries`).
    ///   - targets: every target by its first day.
    ///   - metrics: Health values of the range.
    ///   - dayWeights: reconciled weights from the first weigh-in on (not only the range), so the trend is right.
    ///   - loggedFluidMl: every drink logged in Vitalion per day (water, diary drinks, caffeine drinks); other apps'
    ///     water from `metrics` is added to it (`HydrationTotals`).
    static func build(
        range: ClosedRange<LocalDay>,
        summaries: [DiaryDaySummary],
        targets: EffectiveTimeline<Target>,
        metrics: [DailyHealthMetrics],
        dayWeights: [DayWeight],
        loggedFluidMl: [LocalDay: Double],
    ) -> [DayStats] {
        let summaryByDay = Dictionary(summaries.map { ($0.day, $0) }) { first, _ in first }
        let metricsByDay = Dictionary(metrics.map { ($0.day, $0) }) { first, _ in first }
        let weightByDay = Dictionary(dayWeights.map { ($0.day, $0) }) { first, _ in first }
        let trend = WeightTrend.trendByDay(WeightTrend.samples(dayWeights), through: range.upperBound)
        var result: [DayStats] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            let summary = summaryByDay[day]
            let health = metricsByDay[day]
            let water = (loggedFluidMl[day] ?? 0) + (health?.waterMl ?? 0)
            result.append(DayStats(
                day: day,
                // A day marked complete without entries is a logged day with nothing eaten.
                intake: summary.flatMap { $0.entryCount > 0 || $0.isComplete ? $0.totals : nil },
                entryCount: summary?.entryCount ?? 0,
                isComplete: summary?.isComplete ?? false,
                targetKcal: targets.value(on: day)?.kcal,
                steps: health?.steps,
                sleepMin: health?.sleepAsleepMin ?? health?.sleepInBedMin,
                activeKcal: health?.activeKcal,
                basalKcal: health?.basalKcal,
                restingHR: health?.restingHR,
                hrvMs: health?.hrvSDNNms,
                waterMl: water > 0 ? water : nil,
                weightKg: weightByDay[day]?.kg,
                bodyFatPct: weightByDay[day]?.bodyFatPct,
                trendKg: trend[day],
            ))
            day = day.next
        }
        return result
    }
}

/// Reads what `StatsBuilder` needs from the database.
@MainActor
enum StatsLoader {
    /// Weights are read from here on, so the trend of any range starts at the first weigh-in.
    nonisolated static let historyStart = LocalDay(year: 2000, month: 1, day: 1)!

    static func load(_ range: ClosedRange<LocalDay>, environment: AppEnvironment, calendar: Calendar = .current) throws -> [DayStats] {
        guard let diary = environment.diary, let profiles = environment.profiles, let dailyMetrics = environment.dailyMetrics,
              let hydration = environment.hydration
        else { return [] }
        return try StatsBuilder.build(
            range: range,
            summaries: diary.daySummaries(in: range),
            targets: profiles.targetTimeline(),
            metrics: dailyMetrics.metrics(in: range).map(\.metrics),
            dayWeights: dayWeights(through: range.upperBound, environment: environment, calendar: calendar),
            loggedFluidMl: HydrationTotals.loggedMl(hydration.intakes(in: range)),
        )
    }

    /// Manual and Health weights merged per day, from the first weigh-in through `lastDay`.
    static func dayWeights(through lastDay: LocalDay, environment: AppEnvironment, calendar: Calendar = .current) throws -> [DayWeight] {
        try dayWeights(through: lastDay, metrics: environment.dailyMetrics, weights: environment.weights, calendar: calendar)
    }

    /// The same, from the repositories.
    nonisolated static func dayWeights(
        through lastDay: LocalDay, metrics: DailyMetricsRepository?, weights: WeightRepository?, calendar: Calendar = .current,
    ) throws -> [DayWeight] {
        guard let dailyMetrics = metrics, let weights, historyStart <= lastDay else { return [] }
        let health = try dailyMetrics.metrics(in: historyStart ... lastDay).map(\.metrics)
        let interval = DateInterval(start: historyStart.startDate(calendar: calendar), end: lastDay.next.startDate(calendar: calendar))
        let manual = try weights.entries(in: interval).map {
            ManualWeight(measuredAt: $0.measuredAt, kg: $0.kg, bodyFatPct: $0.bodyFatPct, enteredAt: $0.createdAt)
        }
        return WeightReconciler.daily(health: health, manual: manual, calendar: calendar)
    }
}
