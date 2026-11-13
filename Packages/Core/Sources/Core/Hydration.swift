import Foundation

// MARK: - Intakes

/// One drink that counts toward the day's fluid: `ml` drunk at `at`.
///
/// It comes from a water quick-add (`source: .water`), a diary entry for a food that counts as fluid (see
/// ``FluidRule``), or a caffeine quick-add drink (`source: .caffeine`). Only plain water is `kind: .water`; everything
/// else is `.other`.
public struct FluidIntake: Hashable, Sendable, Identifiable {
    /// Plain water, or any other drink.
    public enum Kind: Hashable, Sendable {
        case water, other
    }

    /// Where the intake was logged.
    public enum Source: Hashable, Sendable {
        case water, diary, caffeine
    }

    /// Stable id of the underlying entry, unique across sources.
    public var id: String
    public var ml: Double
    public var at: Date
    public var kind: Kind
    public var source: Source
    /// Display name ("Water", the food's or the drink's name).
    public var name: String

    public init(id: String, ml: Double, at: Date, kind: Kind, source: Source, name: String) {
        self.id = id
        self.ml = ml
        self.at = at
        self.kind = kind
        self.source = source
        self.name = name
    }
}

// MARK: - Daily totals

/// Each day's hydration total: every drink logged in Vitalion (water, diary drinks, caffeine drinks) plus water other
/// apps wrote to Apple Health. Vitalion's own Health samples are already left out of the other apps' water, so nothing
/// is counted twice. The one sum behind the Hydration tile's sparkline and history, the widget, Siri and Trends.
public enum HydrationTotals {
    /// The ml logged in Vitalion per day; days without intakes are absent.
    public static func loggedMl(_ intakes: [LocalDay: [FluidIntake]]) -> [LocalDay: Double] {
        intakes.mapValues { day in day.reduce(0) { $0 + $1.ml } }
    }

    /// Logged plus other apps' water per day; days with neither (0 ml) are absent.
    public static func byDay(intakes: [LocalDay: [FluidIntake]], otherAppsMl: [LocalDay: Double]) -> [LocalDay: Double] {
        loggedMl(intakes).merging(otherAppsMl, uniquingKeysWith: +).filter { $0.value > 0 }
    }
}

// MARK: - Fluid rule

/// Which diary foods count as fluid: liquids that aren't mostly fat (milk and juice count, oil and cream liqueur
/// don't). The user can override the rule per food.
public enum FluidRule {
    /// Liquids with more fat than this per 100 g/ml don't count as fluid.
    public static let maxFatPer100 = 50.0

    /// Whether a food counts as fluid. An explicit `override` wins; otherwise liquids with at most
    /// ``maxFatPer100`` fat per 100 count.
    public static func counts(isLiquid: Bool, fatPer100: Double, override: Bool?) -> Bool {
        if let override {
            return override
        }
        return isLiquid && fatPer100 <= maxFatPer100
    }
}

// MARK: - Goal

/// How the daily hydration goal is set.
public enum HydrationGoalMode: String, Codable, Sendable {
    /// From body weight (``HydrationGoal/mlPerKg``).
    case weight
    /// A fixed amount the user chose.
    case fixed
}

/// The daily fluid goal: 30 ml per kg body weight (a common rule of thumb for total drinking fluid in adults),
/// rounded to 50 ml, or a fixed amount.
public enum HydrationGoal {
    public static let mlPerKg = 30.0
    /// The goal in weight mode when no usable weight is known.
    public static let fallbackMl = 2500.0

    /// The goal in ml. Weight mode: `round(30 · kg / 50) · 50`, or ``fallbackMl`` without a positive, finite weight.
    /// Fixed mode: `fixedMl`, whatever the weight.
    public static func ml(weightKg: Double?, mode: HydrationGoalMode, fixedMl: Double) -> Double {
        switch mode {
        case .fixed:
            return fixedMl
        case .weight:
            guard let weightKg, weightKg > 0, weightKg.isFinite else { return fallbackMl }
            return (mlPerKg * weightKg).rounded(toMultipleOf: 50)
        }
    }
}

// MARK: - Day

/// A stretch of the waking window with no timed drink for longer than the gap threshold.
public struct HydrationGap: Hashable, Sendable {
    public var start: Date
    public var end: Date
    /// The gap runs up to now: no drink since `start`.
    public var isOngoing: Bool

    public init(start: Date, end: Date, isOngoing: Bool) {
        self.start = start
        self.end = end
        self.isOngoing = isOngoing
    }
}

/// Where the day stands, in precedence order: goal reached beats an ongoing gap beats being behind pace.
public enum HydrationStatus: Hashable, Sendable {
    case goalReached
    /// No drink since `since` for longer than the gap threshold.
    case inGap(since: Date)
    /// Below the pace line by `byMl` (at least the behind margin).
    case behind(byMl: Double)
    case onPace
}

/// One day of drinking against the goal, evaluated at `now`.
///
/// - Totals: every intake counts, whenever it was taken (a drink at 02:00 counts for the day), plus water other apps
///   wrote to Apple Health (`otherAppsMl`, untimed).
/// - Pace: 0 ml at `wake`, rising linearly to `goalMl` at ``paceEnd`` (an hour before `bedtime`, so the goal isn't
///   reached by drinking just before sleep), flat after.
/// - Gaps: stretches inside `[wake, min(now, bedtime)]` without a timed intake that are longer than `gapThreshold`.
///   Other-apps water has no time and doesn't close a gap.
///
/// The window is invalid when `wake` isn't before ``paceEnd`` (e.g. wake 22:30 with bedtime 23:00): then there is no
/// pace and there are no gaps, and the status is ``HydrationStatus/onPace`` unless the goal is reached.
public struct HydrationDay: Sendable {
    public let goalMl: Double
    public let wake: Date
    public let bedtime: Date
    public let gapThreshold: TimeInterval
    public let behindMarginMl: Double
    public let now: Date

    /// Every intake of the day in time order, also those outside the waking window.
    public let intakes: [FluidIntake]
    public let totalMl: Double
    /// Plain water from timed intakes.
    public let waterMl: Double
    /// Every other timed drink (diary fluids, caffeine drinks).
    public let otherDrinksMl: Double
    /// Water other apps wrote to Apple Health.
    public let otherAppsMl: Double
    /// Running total of the timed intakes, in time order (other-apps water excluded).
    public let steps: [(at: Date, totalMl: Double)]
    /// The latest timed intake at or before `now`.
    public let lastIntakeAt: Date?
    public let gaps: [HydrationGap]

    public init(
        intakes: [FluidIntake],
        otherAppsMl: Double,
        goalMl: Double,
        wake: Date,
        bedtime: Date,
        gapThreshold: TimeInterval,
        behindMarginMl: Double,
        now: Date,
    ) {
        self.goalMl = goalMl
        self.wake = wake
        self.bedtime = bedtime
        self.gapThreshold = gapThreshold
        self.behindMarginMl = behindMarginMl
        self.now = now
        self.otherAppsMl = otherAppsMl

        let sorted = intakes.sorted { $0.at < $1.at }
        self.intakes = sorted
        waterMl = sorted.filter { $0.kind == .water }.reduce(0) { $0 + $1.ml }
        otherDrinksMl = sorted.filter { $0.kind == .other }.reduce(0) { $0 + $1.ml }
        totalMl = waterMl + otherDrinksMl + otherAppsMl

        var running = 0.0
        steps = sorted.map { intake in
            running += intake.ml
            return (at: intake.at, totalMl: running)
        }
        lastIntakeAt = sorted.last { $0.at <= now }?.at

        // Same as `isWindowValid`, which can't be called before every stored property is set.
        gaps = wake < bedtime.addingTimeInterval(-Self.paceLeadTime)
            ? Self.gaps(in: sorted.map(\.at), wake: wake, end: min(now, bedtime), now: now, threshold: gapThreshold)
            : []
    }

    /// How long before bedtime the pace line reaches the goal: an hour.
    public static let paceLeadTime: TimeInterval = 3600

    /// When the pace line reaches the goal: ``paceLeadTime`` before bedtime.
    public var paceEnd: Date {
        bedtime.addingTimeInterval(-Self.paceLeadTime)
    }

    /// Whether there is a waking window to pace and find gaps in: `wake` before ``paceEnd``.
    public var isWindowValid: Bool {
        wake < paceEnd
    }

    /// The amount (ml) the pace line expects by `date`: 0 up to `wake`, linear to `goalMl` at ``paceEnd``, `goalMl`
    /// after. Nil when the window is invalid.
    public func pace(at date: Date) -> Double? {
        guard isWindowValid else { return nil }
        let span = paceEnd.timeIntervalSince(wake)
        let elapsed = min(max(date.timeIntervalSince(wake), 0), span)
        return goalMl * elapsed / span
    }

    public var status: HydrationStatus {
        if totalMl >= goalMl {
            return .goalReached
        }
        if let ongoing = gaps.last, ongoing.isOngoing {
            return .inGap(since: ongoing.start)
        }
        if let expected = pace(at: now), expected - totalMl >= behindMarginMl {
            return .behind(byMl: expected - totalMl)
        }
        return .onPace
    }

    /// The first moment the pace line is `behindMarginMl` above the current total, solved from the linear pace:
    /// `wake + (totalMl + margin) / goalMl · (paceEnd − wake)`. Nil when that amount is never expected (it reaches
    /// the goal) or the window is invalid. May lie before `now` (already behind).
    var behindAt: Date? {
        let expected = totalMl + behindMarginMl
        guard isWindowValid, expected < goalMl else { return nil }
        return wake.addingTimeInterval(expected * paceEnd.timeIntervalSince(wake) / goalMl)
    }

    /// Gaps between `wake`, each drink in `[wake, end]`, and `end`; the last one is ongoing when `end` is `now`.
    private static func gaps(in dates: [Date], wake: Date, end: Date, now: Date, threshold: TimeInterval) -> [HydrationGap] {
        guard end > wake else { return [] }
        var gaps: [HydrationGap] = []
        var boundary = wake
        for date in dates where date >= wake && date <= end {
            if date.timeIntervalSince(boundary) > threshold {
                gaps.append(HydrationGap(start: boundary, end: date, isOngoing: false))
            }
            boundary = date
        }
        if end.timeIntervalSince(boundary) > threshold {
            gaps.append(HydrationGap(start: boundary, end: end, isOngoing: end == now))
        }
        return gaps
    }
}

// MARK: - Reminder

/// When to nudge the user to drink next.
public enum HydrationReminder {
    public struct Plan: Hashable, Sendable {
        public var date: Date
        public var reason: Reason

        public init(date: Date, reason: Reason) {
            self.date = date
            self.reason = reason
        }
    }

    public enum Reason: Hashable, Sendable {
        /// No drink since `since`; the reminder is at `since` + gap threshold.
        case gap(since: Date)
        /// The pace line expects `expectedMl` by then, the behind margin above the current total.
        case behind(expectedMl: Double)
    }

    /// The next reminder for `day`, or nil when the goal is reached.
    ///
    /// Two candidates: the gap time (`max(last drink, wake) + threshold`) and the behind time (see the pace line in
    /// ``HydrationDay``). The earliest wins; one already in the past is moved to `now` and keeps its reason (a behind
    /// reason then carries the pace at `now`). When
    /// neither lands by ``HydrationDay/paceEnd`` (or the window is invalid), the plan is tomorrow at
    /// `tomorrowWake + threshold` for a gap since `tomorrowWake`.
    public static func next(day: HydrationDay, tomorrowWake: Date) -> Plan? {
        guard day.totalMl < day.goalMl else { return nil }
        var candidates: [Plan] = []
        if day.isWindowValid {
            let since = max(day.lastIntakeAt ?? day.wake, day.wake)
            candidates.append(Plan(date: since.addingTimeInterval(day.gapThreshold), reason: .gap(since: since)))
            if let behindAt = day.behindAt {
                candidates.append(Plan(date: behindAt, reason: .behind(expectedMl: day.totalMl + day.behindMarginMl)))
            }
        }
        if let earliest = candidates.min(by: { $0.date < $1.date }) {
            let date = max(earliest.date, day.now)
            if date <= day.paceEnd {
                switch earliest.reason {
                case .gap:
                    return Plan(date: date, reason: earliest.reason)
                case .behind:
                    // What the pace line expects at the planned time, which is more than total + margin when the
                    // behind time has passed and the plan was moved to now.
                    let expected = day.pace(at: date) ?? (day.totalMl + day.behindMarginMl)
                    return Plan(date: date, reason: .behind(expectedMl: expected))
                }
            }
        }
        return Plan(date: tomorrowWake.addingTimeInterval(day.gapThreshold), reason: .gap(since: tomorrowWake))
    }
}
