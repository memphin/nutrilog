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
    /// other days are treated as missing (SPEC §5.4.1 inputs). `AdaptiveTDEE.estimate` additionally leaves out logged
    /// days that look only partly logged (see `AdaptiveTDEE.partialDayFraction`).
    public var isLogged: Bool {
        AdaptiveTDEE.isLogged(entryCount: entryCount, isComplete: isComplete)
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
        case .low: String(localized: "Low confidence", bundle: .module)
        case .medium: String(localized: "Medium confidence", bundle: .module)
        case .high: String(localized: "High confidence", bundle: .module)
        }
    }
}

/// How the window's weight change was measured (SPEC §5.4.1 step 3).
public enum TDEEWeightMethod: String, Hashable, Sendable, Codable, CaseIterable {
    /// The difference of the smoothed weight trend between the window's ends. Used once the trend is mature: it
    /// reaches back at least `AdaptiveTDEE.matureTrendDays` without a long gap and the window has at least
    /// `AdaptiveTDEE.denseWeighIns` weigh-ins.
    case trend
    /// A least-squares straight line through the window's weigh-ins, its slope × the span. Used while the trend is young,
    /// restarting after a long gap, or fed by sparse weigh-ins: the trend then still lags its start (or the gap) and its
    /// difference would read that catch-up as real weight change.
    case weighInLine

    /// One short line for the "how was this computed" sheet.
    public var explanation: String {
        switch self {
        case .trend:
            String(localized: "Weight change measured from your smoothed weight trend.", bundle: .module)
        case .weighInLine:
            String(
                localized: """
                Your weight trend is still young or your weigh-ins are sparse, so the change is measured with a \
                straight line through this window's weigh-ins instead.
                """,
                bundle: .module,
            )
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
            String(
                localized: """
                \(count) of the last \(AdaptiveTDEE.windowDays) days are fully logged; the estimate needs at least \
                \(AdaptiveTDEE.minimumLoggedDays).
                """,
                bundle: .module,
            )
        case let .notEnoughWeighIns(count):
            // One string with integer arguments so the catalog can hold the plural forms ("1 weigh-in").
            String(
                localized: """
                \(count) weigh-ins in the last \(AdaptiveTDEE.windowDays) days; the estimate needs at least \
                \(AdaptiveTDEE.minimumWeighIns).
                """,
                bundle: .module,
            )
        case .trendTooShort:
            String(localized: "Your weight history is too short. Keep weighing in for about a week.", bundle: .module)
        }
    }
}

/// The result of one estimate, with everything needed to explain it (SPEC §5.4.1 step 7).
public struct TDEEEstimate: Hashable, Sendable, Codable {
    /// Last day of the window.
    public var day: LocalDay
    /// The days of the window, oldest first (logged or not).
    public var days: [TDEEDay]
    /// Logged days whose intake was used (partly logged days left out, see `partialDays`).
    public var loggedDays: Int
    public var weighIns: Int
    /// Mean diary energy over the logged days.
    public var meanIntakeKcal: Double
    /// The day the weight change is measured from, and the weight on it: the trend on that day for `.trend`, the fitted
    /// line's value for `.weighInLine` (then the day is the first weigh-in used).
    public var trendStartDay: LocalDay
    public var trendStartKg: Double
    /// The trend (or fitted line) on `day`.
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
    /// How the weight change was measured; nil in estimates stored before this was recorded, which used the trend.
    public var weightMethod: TDEEWeightMethod? = nil
    /// Days that count as logged but were left out of the mean intake as partly logged (not marked complete and below
    /// `AdaptiveTDEE.partialDayFraction` of the window's median); nil in estimates stored before this rule.
    public var partialDays: [LocalDay]? = nil

    /// The method actually used (`.trend` for older stored estimates).
    public var resolvedWeightMethod: TDEEWeightMethod {
        weightMethod ?? .trend
    }

    /// Number of partly logged days left out of the mean intake.
    public var partialDaysLeftOut: Int {
        partialDays?.count ?? 0
    }

    /// True when `day` counts as logged but was left out as partly logged.
    public func isPartial(_ day: LocalDay) -> Bool {
        partialDays?.contains(day) ?? false
    }

    /// True when the day's intake went into the mean.
    public func isUsed(_ day: TDEEDay) -> Bool {
        day.isLogged && !isPartial(day.day)
    }

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

    /// The logged-day rule (SPEC §5.4.1 inputs): marked as fully logged, or at least `minimumEntries` entries. Shared by
    /// the estimate (`TDEEDay.isLogged`) and everything else that must not count a half-logged day (`DayStats.isLogged`).
    public static func isLogged(entryCount: Int, isComplete: Bool) -> Bool {
        isComplete || entryCount >= minimumEntries
    }

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
    /// A logged day not marked complete whose energy is below this share of the median of the window's logged days is
    /// treated as partly logged (e.g. only breakfast with three items) and left out of the mean intake. At least half of
    /// the days are at or above the median, so the rule can never leave out every day.
    public static let partialDayFraction = 0.5
    /// The trend's slope is trusted once it reaches back this many days before the window's end without a long gap:
    /// the start value then weighs 0.9^14 ≈ 23 % at the window's start and the trend difference over the window
    /// understates a steady change by about 11 %, against ~25 % or more at three weeks (SPEC §5.4.1 step 3).
    public static let matureTrendDays = 28
    /// The trend method also needs at least this many weigh-ins in the window (half its days); with fewer, a line through
    /// the weigh-ins measures the change without the trend's step-wise catch-up between them.
    public static let denseWeighIns = 7
    /// Weigh-ins this many days or more apart break the trend's history: the gap-aware trend has then moved at least
    /// 1 − 0.9^14 ≈ 77 % of the way to the new weigh-in, so it restarts there for the maturity rule.
    public static let restartGapDays = 14
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
    /// Steps (SPEC §5.4.1): window of 14 days. Logged days that look partly logged (not marked complete, below half
    /// the window's median) are left out; 7 remaining logged days are needed. `ΔE = Δweight × 7,700`, where Δweight is
    /// the trend difference once the trend is mature (`matureTrendDays`, `denseWeighIns`) and otherwise the slope of a
    /// least-squares line through the window's weigh-ins × span. `raw = mean(kcalIn over logged days) − ΔE / span`.
    /// Blend `0.7 × raw + 0.3 × previous`, then clamp to ±25 % of the baseline unless confidence is high (which needs
    /// the mature trend).
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
        let counted = window.filter(\.isLogged)
        let partial = partialDays(counted)
        let logged = counted.filter { !partial.contains($0.day) }
        guard logged.count >= minimumLoggedDays else { return .failure(.notEnoughLoggedDays(logged.count)) }
        let weighIns = window.count(where: { $0.weightKg != nil })
        guard weighIns >= minimumWeighIns else { return .failure(.notEnoughWeighIns(weighIns)) }

        let weighInDays = byDay.values.filter { $0.day <= endDay && $0.weightKg != nil }.map(\.day).sorted()
        let since = trendStart(weighInDays: weighInDays)
        let isMature = (since.map { $0.days(until: endDay) >= matureTrendDays } ?? false) && weighIns >= denseWeighIns
        // A mature trend's difference is smoother than any line; while it is young, restarting or sparse it lags, so the
        // line through the weigh-ins measures the change (also when a caller passed no trend values at all).
        let change: WeightChange
        if isMature, let fromTrend = trendChange(byDay: byDay, window: window, start: start, endDay: endDay) {
            change = fromTrend
        } else {
            guard let since,
                  let fromLine = lineChange(byDay: byDay, from: max(start.previous, since), endDay: endDay)
            else { return .failure(.trendTooShort) }
            change = fromLine
        }
        guard change.span >= minimumTrendSpanDays else { return .failure(.trendTooShort) }

        let meanIntake = logged.reduce(0) { $0 + $1.kcalIn } / Double(logged.count)
        let raw = meanIntake - (change.endKg - change.startKg) * Energy.kcalPerKg / Double(change.span)
        let confidence = confidence(
            byDay: byDay, endDay: endDay, loggedInWindow: logged.count, weighIns: weighIns,
            weightIsMature: change.method == .trend,
        )

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
            trendStartDay: change.startDay, trendStartKg: change.startKg, trendEndKg: change.endKg, trendSpanDays: change.span,
            rawKcal: raw, previousKcal: previousKcal, baselineKcal: baselineKcal, wasClamped: clamped,
            kcal: value, confidence: confidence, underLoggingSuspected: underLogging,
            weightMethod: change.method, partialDays: window.map(\.day).filter(partial.contains),
        ))
    }

    /// The weight change of a window: from `startDay` (weight `startKg`) to the window's end (`endKg`), `span` days.
    struct WeightChange {
        var method: TDEEWeightMethod
        var startDay: LocalDay
        var startKg: Double
        var endKg: Double
        var span: Int
    }

    /// Logged days (of `logged`) that look partly logged: not marked complete and below `partialDayFraction` of the
    /// median energy of `logged`.
    static func partialDays(_ logged: [TDEEDay]) -> Set<LocalDay> {
        let kcal = logged.map(\.kcalIn).sorted()
        guard !kcal.isEmpty else { return [] }
        let middle = kcal.count / 2
        let median = kcal.count.isMultiple(of: 2) ? (kcal[middle - 1] + kcal[middle]) / 2 : kcal[middle]
        let threshold = median * partialDayFraction
        return Set(logged.filter { !$0.isComplete && $0.kcalIn < threshold }.map(\.day))
    }

    /// The first weigh-in of the trend's current run: the earliest weigh-in reached from the last one without a gap of
    /// `restartGapDays` or more. Nil without weigh-ins. `weighInDays` must be sorted.
    static func trendStart(weighInDays: [LocalDay]) -> LocalDay? {
        guard var start = weighInDays.last else { return nil }
        for earlier in weighInDays.dropLast().reversed() {
            guard earlier.days(until: start) < restartGapDays else { break }
            start = earlier
        }
        return start
    }

    /// The trend difference: from the day before the window (so 14 days of intake face 14 days of change) when the
    /// trend already existed then, else from the first window day that has a trend.
    static func trendChange(byDay: [LocalDay: TDEEDay], window: [TDEEDay], start: LocalDay, endDay: LocalDay) -> WeightChange? {
        let candidates = [byDay[start.previous]].compactMap(\.self) + window
        guard let first = candidates.first(where: { $0.trendKg != nil }), let trendStart = first.trendKg,
              let trendEnd = window.last?.trendKg
        else { return nil }
        return WeightChange(method: .trend, startDay: first.day, startKg: trendStart, endKg: trendEnd, span: first.day.days(until: endDay))
    }

    /// A least-squares line through the weigh-ins from `from` (at the earliest the day before the window) to `endDay`,
    /// leaving out weigh-ins the trend marks as outliers. The change runs from the first weigh-in used to `endDay`
    /// along the line. Nil with fewer than two weigh-ins or when they span less than `minimumTrendSpanDays`.
    static func lineChange(byDay: [LocalDay: TDEEDay], from: LocalDay, endDay: LocalDay) -> WeightChange? {
        var samples: [LocalDay: Double] = [:]
        for day in byDay.values where day.day <= endDay {
            if let kg = day.weightKg {
                samples[day.day] = kg
            }
        }
        let outliers = Set(WeightTrend.compute(samples: samples, through: endDay).filter(\.isOutlier).map(\.day))
        let points = samples.filter { $0.key >= from && !outliers.contains($0.key) }.sorted { $0.key < $1.key }
        guard let first = points.first?.key, let last = points.last?.key, points.count >= 2,
              first.days(until: last) >= minimumTrendSpanDays
        else { return nil }
        guard let fit = Correlation.linearFit(points.map { CorrelationPoint(x: Double(first.days(until: $0.key)), y: $0.value) })
        else { return nil }
        let span = first.days(until: endDay)
        return WeightChange(
            method: .weighInLine, startDay: first, startKg: fit.intercept, endKg: fit.y(at: Double(span)), span: span,
        )
    }

    /// High: data reaches back `highConfidenceDays`, ≥ 80 % of those days are logged and the weight change came from a
    /// mature trend (`weightIsMature`: `matureTrendDays` of trend and `denseWeighIns` weigh-ins in the window). Medium:
    /// ≥ 10 logged days and ≥ 4 weigh-ins in the window. Low otherwise.
    static func confidence(
        byDay: [LocalDay: TDEEDay], endDay: LocalDay, loggedInWindow: Int, weighIns: Int, weightIsMature: Bool,
    ) -> TDEEConfidence {
        let long = (0 ..< highConfidenceDays).compactMap { byDay[endDay.adding(days: -$0)] }
        let longLogged = long.count(where: \.isLogged)
        let reachesBack = byDay.keys.contains { $0 <= endDay.adding(days: -(highConfidenceDays - 1)) && (byDay[$0]?.isLogged ?? false) }
        if weightIsMature, reachesBack, Double(longLogged) >= highConfidenceLoggedShare * Double(highConfidenceDays), weighIns >= mediumWeighIns {
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
