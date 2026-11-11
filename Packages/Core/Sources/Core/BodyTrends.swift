import Foundation

// Dashboard math for weight, body fat, resting heart rate and HRV (backlog #28, #29; SPEC FR-41, FR-47, FR-48).
// Pure functions on plain values, so every rule is unit-tested without a database or Health.

// MARK: - Reconciling manual and Health weights

/// A weight Vitalion's user entered by hand (`weight_entry`).
public struct ManualWeight: Hashable, Sendable {
    public var measuredAt: Date
    public var kg: Double
    public var bodyFatPct: Double?
    /// When the entry was made (`created_at`); nil means `measuredAt`.
    public var enteredAt: Date?

    public init(measuredAt: Date, kg: Double, bodyFatPct: Double? = nil, enteredAt: Date? = nil) {
        self.measuredAt = measuredAt
        self.kg = kg
        self.bodyFatPct = bodyFatPct
        self.enteredAt = enteredAt
    }

    /// Later entries first: by entry time, then by measurement time.
    static func enteredLater(_ lhs: ManualWeight, _ rhs: ManualWeight) -> Bool {
        let left = lhs.enteredAt ?? lhs.measuredAt
        let right = rhs.enteredAt ?? rhs.measuredAt
        return left != right ? left > right : lhs.measuredAt > rhs.measuredAt
    }
}

/// The weight (and body fat) that counts for one day.
public struct DayWeight: Hashable, Sendable {
    public var day: LocalDay
    public var kg: Double?
    public var bodyFatPct: Double?
    /// True when `kg` comes from a manual entry.
    public var isManual: Bool

    public init(day: LocalDay, kg: Double?, bodyFatPct: Double?, isManual: Bool) {
        self.day = day
        self.kg = kg
        self.bodyFatPct = bodyFatPct
        self.isManual = isManual
    }
}

/// Merges manual weights with the values read from Health (`daily_metrics`).
///
/// Vitalion writes manual weights to Health too, but the Health sync ignores Vitalion's own weight samples
/// (`DailyMetricsAggregator.aggregate(_:calendar:excludingOwnSamplesFrom:)`), so a manual weigh-in is never counted
/// twice: it reaches the dashboard only through `weight_entry`, immediately, whether or not writing to Health is on.
///
/// Per day: a manual weigh-in wins over the Health value (the user typed it on purpose, e.g. to correct a scale).
/// With several manual entries on one day, the one entered last wins — a later entry is usually a correction. Body
/// fat comes from that entry when it has one, else from the latest other manual entry with one, else from Health.
public enum WeightReconciler {
    public static func daily(
        health: [DailyHealthMetrics],
        manual: [ManualWeight],
        calendar: Calendar = .current,
    ) -> [DayWeight] {
        var result: [LocalDay: DayWeight] = [:]
        for metrics in health where metrics.weightKg != nil || metrics.bodyFatPct != nil {
            result[metrics.day] = DayWeight(day: metrics.day, kg: metrics.weightKg, bodyFatPct: metrics.bodyFatPct, isManual: false)
        }
        let manualByDay = Dictionary(grouping: manual) { LocalDay($0.measuredAt, calendar: calendar) }
        for (day, entries) in manualByDay {
            let sorted = entries.sorted(by: ManualWeight.enteredLater)
            guard let chosen = sorted.first else { continue }
            let fat = chosen.bodyFatPct ?? sorted.first { $0.bodyFatPct != nil }?.bodyFatPct ?? result[day]?.bodyFatPct
            result[day] = DayWeight(day: day, kg: chosen.kg, bodyFatPct: fat, isManual: true)
        }
        return result.values.sorted { $0.day < $1.day }
    }
}

// MARK: - Weight trend

/// Weight on the dashboard: the latest weigh-in, the trend and how the trend moved in a week (FR-41).
public struct WeightSummary: Hashable, Sendable {
    /// The most recent day with a weight.
    public var latest: DayWeight
    public var latestKg: Double
    /// The trend (EMA) on the summary's day.
    public var trendKg: Double
    /// Trend today minus trend seven days earlier; nil when the history doesn't reach back that far.
    public var trendChange7d: Double?

    public init(latest: DayWeight, latestKg: Double, trendKg: Double, trendChange7d: Double?) {
        self.latest = latest
        self.latestKg = latestKg
        self.trendKg = trendKg
        self.trendChange7d = trendChange7d
    }
}

/// One day of the weight trend (backlog #33).
public struct WeightTrendPoint: Hashable, Sendable {
    public var day: LocalDay
    /// The smoothed weight on `day`.
    public var trendKg: Double
    /// The weigh-in of the day; nil when the trend was carried forward.
    public var weightKg: Double?
    /// True when the weigh-in jumped more than `WeightTrend.outlierJump` and was down-weighted.
    public var isOutlier: Bool

    public init(day: LocalDay, trendKg: Double, weightKg: Double?, isOutlier: Bool) {
        self.day = day
        self.trendKg = trendKg
        self.weightKg = weightKg
        self.isOutlier = isOutlier
    }
}

/// The weight trend: an exponential moving average of daily weights (SPEC §5.4.1 step 1, backlog #33).
public enum WeightTrend {
    /// Smoothing factor of the trend: a weigh-in the day after the previous one moves it by 10 % of the difference; after
    /// a gap of `g` days by `1 − 0.9^g` (SPEC §5.4.1).
    public static let defaultAlpha = 0.1
    /// A weigh-in more than 2.5 % away from the previous accepted one counts as a jump (water, a different scale).
    public static let outlierJump = 0.025
    /// A jump moves the trend with only this share of `alpha`.
    public static let outlierAlphaFactor = 0.25
    /// Jumps are only judged against a weigh-in at most this many days old; after a longer gap any change is plausible.
    public static let outlierMaxGapDays = 3

    /// The usual N-day EMA smoothing factor, 2 / (N + 1): 0.25 for 7 days.
    public static func alpha(days: Int) -> Double {
        2 / Double(max(days, 1) + 1)
    }

    /// How far a weigh-in moves the trend when the previous weigh-in was `gapDays` days earlier:
    /// `1 − (1 − alpha)^gapDays`. One day apart that is `alpha`; after a gap the trend has decayed for every missed day,
    /// as if it had been updated daily, so a long gap effectively restarts it (SPEC §5.4.1 step 1).
    public static func gapAlpha(_ alpha: Double, gapDays: Int) -> Double {
        // Exactly `alpha` for consecutive days, so daily weigh-ins give bit-for-bit the classic EMA.
        gapDays <= 1 ? alpha : 1 - pow(1 - alpha, Double(gapDays))
    }

    /// The plain (gap-aware) EMA for every day from the first weigh-in through `lastDay`. The first weigh-in starts the
    /// trend; each later weigh-in moves it by ``gapAlpha(_:gapDays:)`` of the difference — `alpha` for consecutive
    /// days; days without one carry the previous value forward.
    public static func ema(
        _ weights: [LocalDay: Double],
        through lastDay: LocalDay,
        alpha: Double = defaultAlpha,
    ) -> [LocalDay: Double] {
        guard var day = weights.keys.min(), day <= lastDay else { return [:] }
        var trend: Double?
        var previous: LocalDay?
        var result: [LocalDay: Double] = [:]
        while day <= lastDay {
            if let weight = weights[day] {
                let step = gapAlpha(alpha, gapDays: previous.map { $0.days(until: day) } ?? 1)
                trend = trend.map { $0 + step * (weight - $0) } ?? weight
                previous = day
            }
            result[day] = trend
            day = day.next
        }
        return result
    }

    /// The trend for every day from the first weigh-in through `lastDay` (default: the last weigh-in), oldest first.
    ///
    /// Like ``ema(_:through:alpha:)`` (gap-aware: a weigh-in `g` days after the previous one moves the trend by
    /// `1 − (1 − alpha)^g`), but a weigh-in that jumps more than ``outlierJump`` from the previous accepted
    /// weigh-in (at most ``outlierMaxGapDays`` days earlier) is down-weighted: it moves the trend with
    /// `gapAlpha × outlierAlphaFactor`, so one salty dinner barely shows. When the next weigh-in confirms the new level
    /// (within the threshold of the jump), it is accepted normally — a real change is followed, just a day late.
    public static func compute(
        samples: [LocalDay: Double],
        through lastDay: LocalDay? = nil,
        alpha: Double = defaultAlpha,
    ) -> [WeightTrendPoint] {
        guard var day = samples.keys.min(), let end = lastDay ?? samples.keys.max(), day <= end else { return [] }
        var trend: Double?
        var accepted: (day: LocalDay, kg: Double)?
        var pendingJump: Double?
        var previous: LocalDay?
        var result: [WeightTrendPoint] = []
        while day <= end {
            var isOutlier = false
            if let weight = samples[day] {
                // Days since the previous weigh-in (accepted or not): the trend has decayed once per day of the gap.
                let step = gapAlpha(alpha, gapDays: previous.map { $0.days(until: day) } ?? 1)
                previous = day
                if let current = trend {
                    if let reference = accepted, reference.kg > 0,
                       reference.day.days(until: day) <= outlierMaxGapDays,
                       abs(weight - reference.kg) / reference.kg > outlierJump,
                       !(pendingJump.map { $0 > 0 && abs(weight - $0) / $0 <= outlierJump } ?? false)
                    {
                        isOutlier = true
                        pendingJump = weight
                        trend = current + step * outlierAlphaFactor * (weight - current)
                    } else {
                        pendingJump = nil
                        accepted = (day, weight)
                        trend = current + step * (weight - current)
                    }
                } else {
                    trend = weight
                    accepted = (day, weight)
                }
            }
            if let trend {
                result.append(WeightTrendPoint(day: day, trendKg: trend, weightKg: samples[day], isOutlier: isOutlier))
            }
            day = day.next
        }
        return result
    }

    /// ``compute(samples:through:alpha:)`` as day → trend.
    public static func trendByDay(
        _ samples: [LocalDay: Double],
        through lastDay: LocalDay? = nil,
        alpha: Double = defaultAlpha,
    ) -> [LocalDay: Double] {
        var result: [LocalDay: Double] = [:]
        for point in compute(samples: samples, through: lastDay, alpha: alpha) {
            result[point.day] = point.trendKg
        }
        return result
    }

    /// Day → weight for the days of `weights` that have one.
    public static func samples(_ weights: [DayWeight]) -> [LocalDay: Double] {
        var result: [LocalDay: Double] = [:]
        for weight in weights {
            if let kg = weight.kg {
                result[weight.day] = kg
            }
        }
        return result
    }

    /// Latest weight, trend on `today` and the 7-day trend change; nil when no day up to `today` has a weight.
    public static func summary(_ weights: [DayWeight], today: LocalDay) -> WeightSummary? {
        let known = weights.filter { $0.day <= today }
        guard let latest = known.filter({ $0.kg != nil }).max(by: { $0.day < $1.day }), let latestKg = latest.kg else {
            return nil
        }
        let trend = trendByDay(samples(known), through: today)
        guard let trendToday = trend[today] else { return nil }
        let change = trend[today.adding(days: -7)].map { trendToday - $0 }
        return WeightSummary(latest: latest, latestKg: latestKg, trendKg: trendToday, trendChange7d: change)
    }
}

// MARK: - Baselines (resting HR, HRV)

/// A value compared with its own recent history (FR-48), e.g. "HRV 12% below your 30-day average".
public struct BaselineComparison: Hashable, Sendable {
    /// The day of `value` (the most recent day with data).
    public var day: LocalDay
    public var value: Double
    /// Mean of the last 7 days up to and including `day`.
    public var average7: Double
    /// Mean of the 30 days before `day` (not counting it); nil with fewer than `MetricBaseline.minimumDays` values.
    public var average30: Double?

    public init(day: LocalDay, value: Double, average7: Double, average30: Double?) {
        self.day = day
        self.value = value
        self.average7 = average7
        self.average30 = average30
    }

    /// (value − 30-day average) / 30-day average: −0.12 is 12% below. Nil without a baseline.
    public var deviation: Double? {
        guard let average30, average30 > 0 else { return nil }
        return (value - average30) / average30
    }

    /// "12% below your 30-day average", "In line with your 30-day average" (within ±1%); nil without a baseline.
    public var deviationText: String? {
        guard let deviation, deviation.isFinite else { return nil }
        let percent = DisplayRounding.whole(abs(deviation) * 100)
        if percent < 1 {
            return "In line with your 30-day average"
        }
        return "\(percent)% \(deviation < 0 ? "below" : "above") your 30-day average"
    }
}

public enum MetricBaseline {
    /// The 30-day average needs at least this many days with data.
    public static let minimumDays = 7
    /// A value older than this many days before `today` is not shown as current.
    public static let maximumAgeDays = 7

    /// Compares the most recent value (on or before `today`, at most `maximumAgeDays` old) with the days before it.
    public static func compare(_ values: [LocalDay: Double], today: LocalDay) -> BaselineComparison? {
        guard let day = values.keys.filter({ $0 <= today && $0 >= today.adding(days: -maximumAgeDays) }).max(),
              let value = values[day]
        else { return nil }
        let last7 = (0 ..< 7).compactMap { values[day.adding(days: -$0)] }
        let previous30 = (1 ... 30).compactMap { values[day.adding(days: -$0)] }
        let average30 = previous30.count >= minimumDays ? mean(previous30) : nil
        return BaselineComparison(day: day, value: value, average7: mean(last7), average30: average30)
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
