import Foundation

/// One day of everything the charts and the weekly report show. Built once (by the app, from the diary, targets,
/// Health metrics and weights) and used by both, so a report's numbers match the charts to the unit (backlog #39).
public struct DayStats: Hashable, Sendable {
    public var day: LocalDay
    /// Diary totals; nil when nothing was logged that day.
    public var intake: Nutrients?
    public var entryCount: Int
    public var isComplete: Bool
    /// The calorie target in effect that day.
    public var targetKcal: Double?
    public var steps: Int?
    public var sleepMin: Int?
    public var activeKcal: Double?
    /// Resting (basal) energy from Health.
    public var basalKcal: Double?
    public var restingHR: Double?
    public var hrvMs: Double?
    /// Water from Nutrilog and other apps; nil when there is none.
    public var waterMl: Double?
    public var weightKg: Double?
    public var bodyFatPct: Double?
    public var trendKg: Double?

    public init(
        day: LocalDay, intake: Nutrients? = nil, entryCount: Int = 0, isComplete: Bool = false, targetKcal: Double? = nil,
        steps: Int? = nil, sleepMin: Int? = nil, activeKcal: Double? = nil, basalKcal: Double? = nil, restingHR: Double? = nil,
        hrvMs: Double? = nil,
        waterMl: Double? = nil, weightKg: Double? = nil, bodyFatPct: Double? = nil, trendKg: Double? = nil,
    ) {
        self.day = day
        self.intake = intake
        self.entryCount = entryCount
        self.isComplete = isComplete
        self.targetKcal = targetKcal
        self.steps = steps
        self.sleepMin = sleepMin
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.restingHR = restingHR
        self.hrvMs = hrvMs
        self.waterMl = waterMl
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.trendKg = trendKg
    }

    public var kcal: Double? {
        intake?.kcal
    }

    /// Active + resting energy burned; nil unless both are known (a partial value would read as a low day).
    public var totalBurnedKcal: Double? {
        guard let activeKcal, let basalKcal else { return nil }
        return activeKcal + basalKcal
    }

    public var adherence: Adherence {
        Adherence.band(kcal: kcal, targetKcal: targetKcal)
    }
}

public enum Stats {
    /// Mean of the non-nil values; nil when there are none.
    public static func mean(_ values: some Sequence<Double?>) -> Double? {
        var sum = 0.0
        var count = 0
        for value in values {
            if let value {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}

/// Weekly report (FR-52, backlog #39): averages, best and worst day, intake against the estimated expenditure and
/// the weight trend change.
public struct WeeklyReport: Hashable, Sendable {
    public struct RankedDay: Hashable, Sendable {
        public var day: LocalDay
        public var kcal: Double
        public var targetKcal: Double
        /// `kcal − target`.
        public var difference: Double {
            kcal - targetKcal
        }
    }

    public var start: LocalDay
    public var end: LocalDay
    public var days: [DayStats]
    public var loggedDays: Int
    /// Mean over the logged days.
    public var averageIntake: Nutrients?
    /// Mean of the targets on the logged days.
    public var averageTargetKcal: Double?
    public var averageSteps: Double?
    public var averageSleepMin: Double?
    public var averageWaterMl: Double?
    /// The logged day closest to / farthest from its target; nil without logged days that had a target.
    public var bestDay: RankedDay?
    public var worstDay: RankedDay?
    /// Trend on the last day with one minus the trend on the day before the week (or the first day with one).
    public var trendChangeKg: Double?
    public var trendEndKg: Double?
    /// Estimated maintenance for the week, if known.
    public var expenditureKcal: Double?

    /// Average intake minus estimated expenditure: negative = deficit.
    public var balanceKcal: Double? {
        guard let intake = averageIntake?.kcal, let expenditureKcal else { return nil }
        return intake - expenditureKcal
    }

    /// - Parameters:
    ///   - days: the seven days of the week, oldest first (other lengths work too).
    ///   - trendBefore: the weight trend on the day before the first day, if known.
    ///   - expenditureKcal: the adaptive estimate (or formula baseline) for the week.
    public init(days: [DayStats], trendBefore: Double? = nil, expenditureKcal: Double? = nil) {
        precondition(!days.isEmpty, "a report needs at least one day")
        self.days = days
        start = days[0].day
        end = days[days.count - 1].day
        let logged = days.filter { $0.intake != nil }
        loggedDays = logged.count
        if logged.isEmpty {
            averageIntake = nil
        } else {
            averageIntake = Nutrients.sum(logged.compactMap(\.intake)).scaled(by: 1 / Double(logged.count))
        }
        averageTargetKcal = Stats.mean(logged.map(\.targetKcal))
        averageSteps = Stats.mean(days.map { $0.steps.map(Double.init) })
        averageSleepMin = Stats.mean(days.map { $0.sleepMin.map(Double.init) })
        averageWaterMl = Stats.mean(days.map(\.waterMl))
        let ranked = logged.compactMap { day -> RankedDay? in
            guard let kcal = day.kcal, let target = day.targetKcal, target > 0 else { return nil }
            return RankedDay(day: day.day, kcal: kcal, targetKcal: target)
        }
        bestDay = ranked.min { abs($0.difference) < abs($1.difference) }
        worstDay = ranked.count > 1 ? ranked.max { abs($0.difference) < abs($1.difference) } : nil
        let trends = days.compactMap(\.trendKg)
        trendEndKg = trends.last
        if let last = trends.last, let first = trendBefore ?? trends.first, trendBefore != nil || trends.count > 1 {
            trendChangeKg = last - first
        } else {
            trendChangeKg = nil
        }
        self.expenditureKcal = expenditureKcal
    }
}
