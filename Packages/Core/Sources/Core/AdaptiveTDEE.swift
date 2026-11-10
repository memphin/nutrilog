import Foundation

// Adaptive expenditure estimate (SPEC §5.4.1 steps 2–6, FR-34, backlog #34). Pure functions on plain values: no
// database, no Health. The weight trend comes from `WeightTrend.compute` (step 1).

/// One day of input for the estimate.
public struct TDEEDay: Hashable, Sendable, Codable {
    public var day: LocalDay
    /// Diary energy of the day (0 when nothing was logged).
    public var kcalIn: Double
    /// Number of diary entries.
    public var entryCount: Int
    /// The user marked the day as fully logged (`day_note.is_complete`).
    public var isComplete: Bool
    /// The day's weigh-in, if any.
    public var weightKg: Double?
    /// The weight trend on the day, if it has started.
    public var trendKg: Double?

    public init(day: LocalDay, kcalIn: Double, entryCount: Int, isComplete: Bool, weightKg: Double? = nil, trendKg: Double? = nil) {
        self.day = day
        self.kcalIn = kcalIn
        self.entryCount = entryCount
        self.isComplete = isComplete
        self.weightKg = weightKg
        self.trendKg = trendKg
    }

    /// A day counts as logged when it is marked complete or has at least `AdaptiveTDEE.minimumEntries` entries;
    /// other days are treated as missing (SPEC §5.4.1 inputs).
    public var isLogged: Bool {
        isComplete || entryCount >= AdaptiveTDEE.minimumEntries
    }
}

public enum TDEEConfidence: String, Sendable, Codable, CaseIterable, Comparable {
    case low, medium, high

    public static func < (lhs: TDEEConfidence, rhs: TDEEConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public var title: String {
        switch self {
        case .low: "Low confidence"
        case .medium: "Medium confidence"
        case .high: "High confidence"
        }
    }
}

/// Why no estimate can be shown yet.
public enum TDEEUnavailable: Error, Hashable, Sendable {
    /// Fewer than `AdaptiveTDEE.minimumLoggedDays` logged days in the window; the value is how many there are.
    case notEnoughLoggedDays(Int)
    /// Fewer than `AdaptiveTDEE.minimumWeighIns` weigh-ins in the window; the value is how many there are.
    case notEnoughWeighIns(Int)
    /// The weight trend covers fewer than `AdaptiveTDEE.minimumTrendSpanDays` days of the window.
    case trendTooShort

    public var explanation: String {
        switch self {
        case let .notEnoughLoggedDays(count):
            "\(count) of the last \(AdaptiveTDEE.windowDays) days are fully logged; "
                + "the estimate needs at least \(AdaptiveTDEE.minimumLoggedDays)."
        case let .notEnoughWeighIns(count):
            "\(count) weigh-in\(count == 1 ? "" : "s") in the last \(AdaptiveTDEE.windowDays) days; "
                + "the estimate needs at least \(AdaptiveTDEE.minimumWeighIns)."
        case .trendTooShort:
            "Your weight history is too short. Keep weighing in for about a week."
        }
    }
}

/// The result of one estimate, with everything needed to explain it (SPEC §5.4.1 step 7).
public struct TDEEEstimate: Hashable, Sendable, Codable {
    /// Last day of the window.
    public var day: LocalDay
    /// The days of the window, oldest first (logged or not).
    public var days: [TDEEDay]
    public var loggedDays: Int
    public var weighIns: Int
    /// Mean diary energy over the logged days.
    public var meanIntakeKcal: Double
    /// The day the trend change is measured from, and the trend on it.
    public var trendStartDay: LocalDay
    public var trendStartKg: Double
    public var trendEndKg: Double
    /// Days between `trendStartDay` and `day`.
    public var trendSpanDays: Int
    /// `meanIntake − ΔE / span`, before smoothing and clamping.
    public var rawKcal: Double
    /// The previous estimate blended in (0.3), if there was one.
    public var previousKcal: Double?
    /// Mifflin-St Jeor × activity, if the profile is complete.
    public var baselineKcal: Double?
    /// True when the blended value was outside ±25 % of the baseline and was pulled back.
    public var wasClamped: Bool
    /// The estimate: blended with the previous one and clamped until confidence is high.
    public var kcal: Double
    public var confidence: TDEEConfidence
    /// Logged intake looks implausibly low for the weight trend (see `AdaptiveTDEE.estimate`).
    public var underLoggingSuspected: Bool

    public var windowDays: Int {
        days.count
    }

    /// Trend change over the span, in kg (negative = losing).
    public var trendChangeKg: Double {
        trendEndKg - trendStartKg
    }

    /// Trend change scaled to one week.
    public var weeklyChangeKg: Double {
        trendSpanDays > 0 ? trendChangeKg / Double(trendSpanDays) * 7 : 0
    }

    /// Energy stored (+) or released (−) per day according to the trend: `Δkg × 7,700 / span`.
    public var dailyBalanceKcal: Double {
        trendSpanDays > 0 ? trendChangeKg * Energy.kcalPerKg / Double(trendSpanDays) : 0
    }
}

/// A calorie target proposed by the weekly check-in (SPEC §5.4.1 step 6).
public struct TargetProposal: Hashable, Sendable {
    public enum Note: Hashable, Sendable {
        /// `estimate − goal delta`, as is.
        case fromEstimate
        /// Under-logging is suspected and the computed target would be lower: the current target is kept.
        case keptBecauseUnderLogging
        /// The computed target was below the safety floor and was raised to it.
        case raisedToFloor
    }

    public var kcal: Double
    /// `estimate + daily delta of the goal`, rounded to 10 kcal, before any safeguard.
    public var computedKcal: Double
    public var note: Note

    public init(kcal: Double, computedKcal: Double, note: Note) {
        self.kcal = kcal
        self.computedKcal = computedKcal
        self.note = note
    }
}

public enum AdaptiveTDEE {
    /// Rolling window, in days (step 2).
    public static let windowDays = 14
    /// Logged days needed in the window to show an estimate (step 2).
    public static let minimumLoggedDays = 7
    /// A day with fewer entries and no "fully logged" mark is treated as missing.
    public static let minimumEntries = 3
    /// Weigh-ins needed in the window: with fewer the trend is mostly carried forward and says nothing.
    public static let minimumWeighIns = 2
    /// The trend must cover at least this many days of the window.
    public static let minimumTrendSpanDays = 7
    /// Share of the new estimate when blending with the previous one (step 5).
    public static let blendNew = 0.7
    /// Until confidence is high the estimate stays within ±25 % of the formula baseline (step 5).
    public static let clampFraction = 0.25
    /// Days of history looked at for "high" confidence, and the share of them that must be logged (step 2).
    public static let highConfidenceDays = 21
    public static let highConfidenceLoggedShare = 0.8
    /// "Medium" needs this many logged days and weigh-ins in the window.
    public static let mediumLoggedDays = 10
    public static let mediumWeighIns = 4
    /// A raw estimate below this share of the baseline means the intake is probably under-logged.
    public static let underLoggingFraction = 0.75
    /// A single day below this share of the estimate looks under-logged (backlog #36).
    public static let lowDayFraction = 0.5
    /// Proposed targets never go below this (kcal/day).
    public static let minimumTargetKcal: Double = 1200

    /// Estimates maintenance energy for the window ending on `endDay`.
    ///
    /// - Parameters:
    ///   - history: days up to `endDay` in any order, ideally `highConfidenceDays` or more; days missing from it
    ///     count as not logged. `trendKg` should also be set on the day before the window when known.
    ///   - endDay: last day of the window — normally yesterday, since today is still being logged.
    ///   - baselineKcal: Mifflin-St Jeor × activity, or nil when the profile is incomplete (no clamp then).
    ///   - previousKcal: the last stored estimate, blended in with 0.3.
    ///
    /// Steps (SPEC §5.4.1): window of 14 days; needs 7 logged days. `ΔE = (trend_end − trend_start) × 7,700`.
    /// `raw = mean(kcalIn over logged days) − ΔE / span`. Blend `0.7 × raw + 0.3 × previous`, then clamp to ±25 %
    /// of the baseline unless confidence is high.
    ///
    /// Under-logging: eating more than was logged keeps the weight up, so the raw estimate comes out low. When it is
    /// below 75 % of the baseline the result is flagged, and `proposal` then never lowers the target.
    public static func estimate(
        history: [TDEEDay],
        endDay: LocalDay,
        baselineKcal: Double? = nil,
        previousKcal: Double? = nil,
    ) -> Result<TDEEEstimate, TDEEUnavailable> {
        let byDay = Dictionary(history.map { ($0.day, $0) }) { first, _ in first }
        let start = endDay.adding(days: -(windowDays - 1))
        let window = (0 ..< windowDays).map { offset -> TDEEDay in
            let day = start.adding(days: offset)
            return byDay[day] ?? TDEEDay(day: day, kcalIn: 0, entryCount: 0, isComplete: false)
        }
        let logged = window.filter(\.isLogged)
        guard logged.count >= minimumLoggedDays else { return .failure(.notEnoughLoggedDays(logged.count)) }
        let weighIns = window.count(where: { $0.weightKg != nil })
        guard weighIns >= minimumWeighIns else { return .failure(.notEnoughWeighIns(weighIns)) }

        // Trend change: from the day before the window (so 14 days of intake face 14 days of change) when the trend
        // already existed then, else from the first window day that has a trend.
        let candidates = [byDay[start.previous]].compactMap(\.self) + window
        guard let first = candidates.first(where: { $0.trendKg != nil }), let trendStart = first.trendKg,
              let trendEnd = window.last?.trendKg
        else { return .failure(.trendTooShort) }
        let span = first.day.days(until: endDay)
        guard span >= minimumTrendSpanDays else { return .failure(.trendTooShort) }

        let meanIntake = logged.reduce(0) { $0 + $1.kcalIn } / Double(logged.count)
        let raw = meanIntake - (trendEnd - trendStart) * Energy.kcalPerKg / Double(span)
        let confidence = confidence(byDay: byDay, endDay: endDay, loggedInWindow: logged.count, weighIns: weighIns)

        var value = previousKcal.map { blendNew * raw + (1 - blendNew) * $0 } ?? raw
        var clamped = false
        if let baselineKcal, baselineKcal > 0, confidence != .high {
            let range = baselineKcal * (1 - clampFraction) ... baselineKcal * (1 + clampFraction)
            if !range.contains(value) {
                value = min(max(value, range.lowerBound), range.upperBound)
                clamped = true
            }
        }
        let underLogging = baselineKcal.map { $0 > 0 && raw < $0 * underLoggingFraction } ?? false
        return .success(TDEEEstimate(
            day: endDay, days: window, loggedDays: logged.count, weighIns: weighIns, meanIntakeKcal: meanIntake,
            trendStartDay: first.day, trendStartKg: trendStart, trendEndKg: trendEnd, trendSpanDays: span,
            rawKcal: raw, previousKcal: previousKcal, baselineKcal: baselineKcal, wasClamped: clamped,
            kcal: value, confidence: confidence, underLoggingSuspected: underLogging,
        ))
    }

    /// High: data reaches back `highConfidenceDays` and ≥ 80 % of those days are logged. Medium: ≥ 10 logged days
    /// and ≥ 4 weigh-ins in the window. Low otherwise.
    static func confidence(byDay: [LocalDay: TDEEDay], endDay: LocalDay, loggedInWindow: Int, weighIns: Int) -> TDEEConfidence {
        let long = (0 ..< highConfidenceDays).compactMap { byDay[endDay.adding(days: -$0)] }
        let longLogged = long.count(where: \.isLogged)
        let reachesBack = byDay.keys.contains { $0 <= endDay.adding(days: -(highConfidenceDays - 1)) && (byDay[$0]?.isLogged ?? false) }
        if reachesBack, Double(longLogged) >= highConfidenceLoggedShare * Double(highConfidenceDays), weighIns >= mediumWeighIns {
            return .high
        }
        if loggedInWindow >= mediumLoggedDays, weighIns >= mediumWeighIns {
            return .medium
        }
        return .low
    }

    /// The check-in's proposed calorie target: `estimate + goal delta` rounded to 10 kcal (step 6), with two
    /// safeguards: it is never below ``minimumTargetKcal``, and when under-logging is suspected it never goes below
    /// `currentTargetKcal` — the app warns instead of lowering the target (backlog #36).
    public static func proposal(
        for estimate: TDEEEstimate,
        goal: GoalMode,
        rateKgPerWeek: Double,
        currentTargetKcal: Double?,
    ) -> TargetProposal {
        let computed = Energy.calorieTarget(tdee: estimate.kcal, goal: goal, rateKgPerWeek: goal == .maintain ? 0 : rateKgPerWeek)
        if estimate.underLoggingSuspected, let currentTargetKcal, computed < currentTargetKcal {
            return TargetProposal(kcal: currentTargetKcal, computedKcal: computed, note: .keptBecauseUnderLogging)
        }
        if computed < minimumTargetKcal {
            return TargetProposal(kcal: minimumTargetKcal, computedKcal: computed, note: .raisedToFloor)
        }
        return TargetProposal(kcal: computed, computedKcal: computed, note: .fromEstimate)
    }

    /// True when a finished day's logged energy is implausibly low against the estimate (below half of it) and the
    /// day isn't marked as fully logged. Only ever a hint to the user (backlog #36).
    public static func looksUnderLogged(dayKcal: Double, isComplete: Bool, estimateKcal: Double?) -> Bool {
        guard !isComplete, let estimateKcal, estimateKcal > 0 else { return false }
        return dayKcal < estimateKcal * lowDayFraction
    }
}

/// When the weekly check-in is due (SPEC §5.4.1 step 6).
public enum CheckInSchedule {
    /// The most recent day on or before `today` that falls on `weekday` (1 = Sunday … 7 = Saturday).
    public static func latestScheduledDay(onOrBefore today: LocalDay, weekday: Int) -> LocalDay {
        today.adding(days: -((today.weekday - weekday + 7) % 7))
    }

    /// True when the latest scheduled check-in day has no check-in on or after it.
    public static func isDue(today: LocalDay, weekday: Int, lastCheckIn: LocalDay?) -> Bool {
        guard let lastCheckIn else { return true }
        return lastCheckIn < latestScheduledDay(onOrBefore: today, weekday: weekday)
    }
}
