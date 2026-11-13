import Foundation

/// The user's default training weekdays and calorie/hydration boost from `effectiveFrom` on. Like calorie targets,
/// schedules are history: a new one starts on its day and earlier days keep the schedule they had.
public struct TrainingSchedule: Hashable, Sendable, Codable {
    /// The boost when the user has not chosen one (also for days without any schedule).
    public static let defaultBoostPercent = 10
    /// The boosts the user can choose.
    public static let boostPercentRange = 0 ... 100

    public var effectiveFrom: LocalDay
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday (as `LocalDay.weekday`); other numbers are dropped.
    public var weekdays: Set<Int> {
        didSet { weekdays = Self.valid(weekdays) }
    }

    /// How much more energy and fluid a training day gets, in percent.
    public var boostPercent: Int

    public init(effectiveFrom: LocalDay, weekdays: Set<Int>, boostPercent: Int = Self.defaultBoostPercent) {
        self.effectiveFrom = effectiveFrom
        self.weekdays = Self.valid(weekdays)
        self.boostPercent = boostPercent
    }

    /// Whether `day`'s weekday is one of the training weekdays (overrides aside).
    public func includes(_ day: LocalDay) -> Bool {
        weekdays.contains(day.weekday)
    }

    private static func valid(_ weekdays: Set<Int>) -> Set<Int> {
        weekdays.filter { (1 ... 7).contains($0) }
    }
}

/// Which days are training days: the user's switch for that day (an override) if there is one; else a day with a
/// training workout in Apple Health (`workoutDays`) or one of the weekdays of the schedule in effect. Without any
/// schedule no weekday is a training day and the boost is ``TrainingSchedule/defaultBoostPercent``.
public struct TrainingDays: Equatable, Sendable {
    public let timeline: EffectiveTimeline<TrainingSchedule>
    /// Days the user switched on (`true`) or off (`false`).
    public let overrides: [LocalDay: Bool]
    /// Days with a workout that counts as training (`TrainingRules.trainingDays(of:)`): training days whatever the
    /// schedule says, unless the user switched them off.
    public let workoutDays: Set<LocalDay>

    public static let none = TrainingDays(schedules: [], overrides: [:])

    public init(timeline: EffectiveTimeline<TrainingSchedule>, overrides: [LocalDay: Bool], workoutDays: Set<LocalDay> = []) {
        self.timeline = timeline
        self.overrides = overrides
        self.workoutDays = workoutDays
    }

    /// `schedules` in any order; with two on the same day the later one in the array wins.
    public init(schedules: [TrainingSchedule], overrides: [LocalDay: Bool], workoutDays: Set<LocalDay> = []) {
        self.init(
            timeline: EffectiveTimeline(schedules.map { (from: $0.effectiveFrom, value: $0) }), overrides: overrides,
            workoutDays: workoutDays,
        )
    }

    /// The schedule in effect on `day`; nil before the first one.
    public func schedule(on day: LocalDay) -> TrainingSchedule? {
        timeline.value(on: day)
    }

    /// The user's choice for `day`, nil when the day follows its schedule and workouts.
    public func override(on day: LocalDay) -> Bool? {
        overrides[day]
    }

    /// Whether the schedule makes `day` a training day, overrides and workouts aside.
    public func scheduledTraining(_ day: LocalDay) -> Bool {
        schedule(on: day)?.includes(day) ?? false
    }

    /// Whether `day` is a training day without the user's switch: it has a training workout or its schedule says so.
    public func defaultTraining(_ day: LocalDay) -> Bool {
        workoutDays.contains(day) || scheduledTraining(day)
    }

    /// Whether training was planned on `day`: the user's switch, else the schedule. A workout is not a plan.
    public func isPlanned(_ day: LocalDay) -> Bool {
        override(on: day) ?? scheduledTraining(day)
    }

    /// Whether `day` is a training day: its override, else a training workout or its schedule's weekdays.
    public func isTraining(_ day: LocalDay) -> Bool {
        override(on: day) ?? defaultTraining(day)
    }

    /// The boost of the schedule in effect on `day` (``TrainingSchedule/defaultBoostPercent`` without one), whether
    /// or not `day` is a training day.
    public func boostPercent(on day: LocalDay) -> Int {
        schedule(on: day)?.boostPercent ?? TrainingSchedule.defaultBoostPercent
    }

    /// The boost to apply on `day`; nil when it is not a training day.
    public func boost(on day: LocalDay) -> Int? {
        isTraining(day) ? boostPercent(on: day) : nil
    }
}

/// Targets of a training day: more energy (rounded to 10 kcal, like `Energy.calorieTarget`) given as extra carbs
/// (protein, fat and fiber stay), and more fluid (rounded to 50 ml, like `HydrationGoal`).
public enum TrainingBoost {
    /// The calorie target boosted by `percent`, rounded to 10 kcal; never below `kcal`. 0 % leaves it unchanged.
    public static func kcal(_ kcal: Double, percent: Int) -> Double {
        guard percent > 0, kcal.isFinite else { return kcal }
        return max(kcal, (kcal * Double(100 + percent) / 100).rounded(toMultipleOf: 10))
    }

    /// Boosted calories, and carbs raised by the extra energy at 4 kcal/g. 0 % leaves both unchanged.
    /// E.g. 2000 kcal / 200 g carbs at 10 % → 2200 kcal / 250 g.
    public static func apply(kcal: Double, carbsG: Double, percent: Int) -> (kcal: Double, carbsG: Double) {
        let boosted = Self.kcal(kcal, percent: percent)
        return (boosted, carbsG + (boosted - kcal) / Energy.kcalPerGramCarbs)
    }

    /// The fluid goal boosted by `percent`, rounded to 50 ml; never below `ml`. 0 % leaves it unchanged.
    /// E.g. 2500 ml at 10 % → 2750 ml.
    public static func waterMl(_ ml: Double, percent: Int) -> Double {
        guard percent > 0, ml.isFinite else { return ml }
        return max(ml, (ml * Double(100 + percent) / 100).rounded(toMultipleOf: 50))
    }
}
