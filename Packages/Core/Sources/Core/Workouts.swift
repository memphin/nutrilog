import Foundation

// Workouts read from Apple Health (the Training tab). Plain value copies, like the rest of `HealthData.swift`, so the
// rules here — what counts as training, double recordings, the week — are testable without HealthKit.

// MARK: - Kinds

/// What a workout was, by its `HKWorkoutActivityType` raw value. Only the kinds with a name of their own are listed;
/// every other type is ``other``.
public enum WorkoutKind: Int, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case badminton = 4
    case basketball = 6
    case boxing = 8
    case climbing = 9
    case crossTraining = 11
    case cycling = 13
    case elliptical = 16
    case functionalStrength = 20
    case golf = 21
    case handball = 23
    case hiking = 24
    case martialArts = 28
    case mindAndBody = 29
    case rowing = 35
    case running = 37
    case skating = 39
    case soccer = 41
    case squash = 43
    case stairStepper = 44
    case swimming = 46
    case tableTennis = 47
    case tennis = 48
    case strength = 50
    case volleyball = 51
    case walking = 52
    case yoga = 57
    case coreTraining = 59
    case crossCountrySkiing = 60
    case downhillSkiing = 61
    case flexibility = 62
    case highIntensityIntervals = 63
    case jumpRope = 64
    case kickboxing = 65
    case pilates = 66
    case snowboarding = 67
    case stairs = 68
    case mixedCardio = 73
    case dance = 77
    case cooldown = 80
    case multisport = 82
    case other = 3000

    public var id: Int {
        rawValue
    }

    /// The kind of an `HKWorkoutActivityType` raw value. Types Apple renamed map to their successor (dance → cardio
    /// dance, mixed metabolic cardio → mixed cardio); unlisted ones are ``other``.
    public init(activityType: Int) {
        switch activityType {
        case 14, 15, 78: self = .dance // dance and dance-inspired training (both retired), social dance
        case 30: self = .mixedCardio // mixed metabolic cardio training (retired)
        default: self = WorkoutKind(rawValue: activityType) ?? .other
        }
    }

    public var title: String {
        switch self {
        case .badminton: String(localized: "Badminton", bundle: .module)
        case .basketball: String(localized: "Basketball", bundle: .module)
        case .boxing: String(localized: "Boxing", bundle: .module)
        case .climbing: String(localized: "Climbing", bundle: .module)
        case .crossTraining: String(localized: "Cross training", bundle: .module)
        case .cycling: String(localized: "Cycling", bundle: .module)
        case .elliptical: String(localized: "Elliptical", bundle: .module)
        case .functionalStrength: String(localized: "Functional strength training", bundle: .module)
        case .golf: String(localized: "Golf", bundle: .module)
        case .handball: String(localized: "Handball", bundle: .module)
        case .hiking: String(localized: "Hiking", bundle: .module)
        case .martialArts: String(localized: "Martial arts", bundle: .module)
        case .mindAndBody: String(localized: "Mind and body", bundle: .module)
        case .rowing: String(localized: "Rowing", bundle: .module)
        case .running: String(localized: "Running", bundle: .module)
        case .skating: String(localized: "Skating", bundle: .module)
        case .soccer: String(localized: "Soccer", bundle: .module)
        case .squash: String(localized: "Squash", bundle: .module)
        case .stairStepper: String(localized: "Stair stepper", bundle: .module)
        case .swimming: String(localized: "Swimming", bundle: .module)
        case .tableTennis: String(localized: "Table tennis", bundle: .module)
        case .tennis: String(localized: "Tennis", bundle: .module)
        case .strength: String(localized: "Strength training", bundle: .module)
        case .volleyball: String(localized: "Volleyball", bundle: .module)
        case .walking: String(localized: "Walking", bundle: .module)
        case .yoga: String(localized: "Yoga", bundle: .module)
        case .coreTraining: String(localized: "Core training", bundle: .module)
        case .crossCountrySkiing: String(localized: "Cross-country skiing", bundle: .module)
        case .downhillSkiing: String(localized: "Skiing", bundle: .module)
        case .flexibility: String(localized: "Flexibility", bundle: .module)
        case .highIntensityIntervals: String(localized: "HIIT", bundle: .module, comment: "High-intensity interval training")
        case .jumpRope: String(localized: "Jump rope", bundle: .module)
        case .kickboxing: String(localized: "Kickboxing", bundle: .module)
        case .pilates: String(localized: "Pilates", bundle: .module)
        case .snowboarding: String(localized: "Snowboarding", bundle: .module)
        case .stairs: String(localized: "Stairs", bundle: .module)
        case .mixedCardio: String(localized: "Mixed cardio", bundle: .module)
        case .dance: String(localized: "Dance", bundle: .module)
        case .cooldown: String(localized: "Cooldown", bundle: .module)
        case .multisport: String(localized: "Multisport", bundle: .module)
        case .other: String(localized: "Other workout", bundle: .module)
        }
    }
}

// MARK: - Workout

/// One workout from Apple Health (`HKWorkout`).
public struct HealthWorkout: Hashable, Sendable, Codable, Identifiable {
    /// `HKWorkout.uuid`, lowercased.
    public var id: String
    /// The local day the workout started on, in the calendar it was read with.
    public var day: LocalDay
    /// `HKWorkoutActivityType` raw value (kept as is, so a type without a ``WorkoutKind`` is not lost).
    public var activityType: Int
    public var start: Date
    public var end: Date
    /// Time spent working out: `end − start` without the pauses.
    public var durationSec: Double
    /// Active energy burned during the workout; nil when the source recorded none.
    public var activeKcal: Double?
    /// Distance covered, in metres; nil for workouts without one.
    public var distanceM: Double?
    public var source: HealthSource
    /// Started from a custom workout on Apple Watch (one of its steps is in the metadata). The only custom workout in
    /// use is refereeing, so such a workout is called that (see ``automaticTitle``).
    public var isCustomWorkout: Bool
    /// The name the user gave this workout in Vitalion; nil for none.
    public var name: String?

    public init(
        id: String, day: LocalDay, activityType: Int, start: Date, end: Date, durationSec: Double? = nil,
        activeKcal: Double? = nil, distanceM: Double? = nil, source: HealthSource, isCustomWorkout: Bool = false,
        name: String? = nil,
    ) {
        self.id = id
        self.day = day
        self.activityType = activityType
        self.start = start
        self.end = max(end, start)
        self.durationSec = max(durationSec ?? end.timeIntervalSince(start), 0)
        self.activeKcal = activeKcal
        self.distanceM = distanceM
        self.source = source
        self.isCustomWorkout = isCustomWorkout
        self.name = name
    }

    public var kind: WorkoutKind {
        WorkoutKind(activityType: activityType)
    }

    /// What the workout is called without a name of its own: "Refereeing" for a custom workout, else its kind.
    public var automaticTitle: String {
        isCustomWorkout ? String(localized: "Refereeing", bundle: .module, comment: "A workout: refereeing a match") : kind.title
    }

    /// What the workout is called: the user's name for it, else ``automaticTitle``.
    public var title: String {
        if let name = WorkoutName.normalized(name) {
            return name
        }
        return automaticTitle
    }

    /// The duration in whole minutes (rounded).
    public var minutes: Int {
        Int((durationSec / 60).rounded())
    }
}

/// A name the user gives a workout.
public enum WorkoutName {
    /// The longest name kept.
    public static let maxLength = 60

    /// `name` trimmed and cut to ``maxLength``; nil when nothing is left.
    public static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

// MARK: - What counts as training

/// Which workout kinds count as training — the rest (walks, by default) are everyday activity: listed, but never a
/// training session and never a reason for a training day. Like targets and training schedules the choice is
/// history: a change applies from its day on and earlier days keep the kinds they had.
///
/// The first entry is also when workouts began to decide training days: a workout before it is shown, but its day
/// keeps the status it had (FR-32: past days keep their training status).
public struct TrainingRules: Equatable, Sendable {
    /// Not training unless the user says so.
    public static let defaultExcluded: Set<WorkoutKind> = [.walking]

    /// The kinds that do **not** count as training, by the day the choice starts.
    public let timeline: EffectiveTimeline<Set<WorkoutKind>>

    /// No choice made yet: the default kinds, and no workout decides a training day.
    public static let none = TrainingRules(timeline: EffectiveTimeline([]))

    public init(timeline: EffectiveTimeline<Set<WorkoutKind>>) {
        self.timeline = timeline
    }

    /// The kinds that don't count as training, by the first day each choice applies to.
    public init(_ excludedFrom: [LocalDay: Set<WorkoutKind>]) {
        self.init(timeline: EffectiveTimeline(excludedFrom.map { (from: $0.key, value: $0.value) }))
    }

    /// The kinds that don't count as training on `day`. Days before the first choice use that first choice (the
    /// default without any), so old workouts are sorted the way the user first set it up.
    public func excluded(on day: LocalDay) -> Set<WorkoutKind> {
        timeline.value(on: day) ?? timeline.first?.value ?? Self.defaultExcluded
    }

    /// The choice in effect now (the latest one).
    public var currentExcluded: Set<WorkoutKind> {
        timeline.last?.value ?? Self.defaultExcluded
    }

    public func countsAsTraining(_ kind: WorkoutKind, on day: LocalDay) -> Bool {
        !excluded(on: day).contains(kind)
    }

    public func countsAsTraining(_ workout: HealthWorkout) -> Bool {
        countsAsTraining(workout.kind, on: workout.day)
    }

    /// Whether a training workout on `day` makes it a training day: only from the first choice on.
    public func decidesTrainingDays(on day: LocalDay) -> Bool {
        timeline.value(on: day) != nil
    }

    /// The days of `workouts` that a training workout makes a training day.
    public func trainingDays(of workouts: some Sequence<HealthWorkout>) -> Set<LocalDay> {
        Set(workouts.lazy.filter { decidesTrainingDays(on: $0.day) && countsAsTraining($0) }.map(\.day))
    }
}

// MARK: - Double recordings

/// One session recorded twice — by the watch and by a training app, say — is one workout. Workouts that overlap for
/// at least half of the shorter one are the same session; the one shown is a training workout if there is one, then
/// the one from Apple Watch, then the longest. Energy, distance and a name it lacks are taken from its doubles.
public enum WorkoutSessions {
    /// Two workouts are the same session when they share at least this part of the shorter one's time.
    public static let overlapShare = 0.5

    /// `workouts` without doubles, oldest first.
    public static func merged(_ workouts: [HealthWorkout], rules: TrainingRules) -> [HealthWorkout] {
        var groups: [[HealthWorkout]] = []
        for workout in workouts.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            if let index = groups.lastIndex(where: { group in group.contains { isSameSession($0, workout) } }) {
                groups[index].append(workout)
            } else {
                groups.append([workout])
            }
        }
        return groups.map { representative(of: $0, rules: rules) }
    }

    static func isSameSession(_ lhs: HealthWorkout, _ rhs: HealthWorkout) -> Bool {
        let overlap = min(lhs.end, rhs.end).timeIntervalSince(max(lhs.start, rhs.start))
        let shorter = min(lhs.end.timeIntervalSince(lhs.start), rhs.end.timeIntervalSince(rhs.start))
        guard overlap > 0, shorter > 0 else { return false }
        return overlap >= shorter * overlapShare
    }

    private static func representative(of group: [HealthWorkout], rules: TrainingRules) -> HealthWorkout {
        guard var best = group.min(by: { rank($0, rules) < rank($1, rules) }) else {
            preconditionFailure("a session has at least one workout")
        }
        let others = group.filter { $0.id != best.id }
        best.activeKcal = best.activeKcal ?? others.compactMap(\.activeKcal).max()
        best.distanceM = best.distanceM ?? others.compactMap(\.distanceM).max()
        // The same session: a name given to one of its recordings, or a custom workout recorded by any, names it.
        best.name = WorkoutName.normalized(best.name) ?? others.lazy.compactMap { WorkoutName.normalized($0.name) }.first
        best.isCustomWorkout = best.isCustomWorkout || others.contains(where: \.isCustomWorkout)
        return best
    }

    /// Lower is better: training before activity, Apple Watch before other sources, longer before shorter.
    private static func rank(_ workout: HealthWorkout, _ rules: TrainingRules) -> (Int, Int, Double, String) {
        (rules.countsAsTraining(workout) ? 0 : 1, workout.source.kind.rawValue, -workout.durationSec, workout.id)
    }
}

// MARK: - The Training tab

/// One week of training: its sessions and which days were planned.
public struct TrainingWeek: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public var day: LocalDay
        /// Training sessions started that day, oldest first.
        public var sessions: [HealthWorkout]
        /// A training day by the schedule or the user's switch (not by a workout).
        public var isPlanned: Bool

        public init(day: LocalDay, sessions: [HealthWorkout], isPlanned: Bool) {
            self.day = day
            self.sessions = sessions
            self.isPlanned = isPlanned
        }

        public var id: LocalDay {
            day
        }

        public var isTrained: Bool {
            !sessions.isEmpty
        }
    }

    /// The seven days from the week's first day on.
    public var days: [Day]

    public init(days: [Day]) {
        precondition(!days.isEmpty, "a week needs its days")
        self.days = days
    }

    public var start: LocalDay {
        days[0].day
    }

    public var sessions: [HealthWorkout] {
        days.flatMap(\.sessions)
    }

    /// Days with at least one training session.
    public var trainedDays: Int {
        days.count(where: \.isTrained)
    }

    public var plannedDays: Int {
        days.count(where: \.isPlanned)
    }

    public var totalMinutes: Int {
        sessions.reduce(0) { $0 + $1.minutes }
    }
}

/// Workouts that don't count as training (walks, by default) over some days.
public struct ActivitySummary: Equatable, Sendable {
    /// Newest first.
    public var workouts: [HealthWorkout]

    public init(workouts: [HealthWorkout]) {
        self.workouts = workouts
    }

    public var totalMinutes: Int {
        workouts.reduce(0) { $0 + $1.minutes }
    }

    /// The summed distance in metres; nil when no workout has one.
    public var distanceM: Double? {
        let distances = workouts.compactMap(\.distanceM)
        return distances.isEmpty ? nil : distances.reduce(0, +)
    }

    /// Every workout is a walk (the section is then called "Walks").
    public var isOnlyWalks: Bool {
        workouts.allSatisfy { $0.kind == .walking }
    }
}

/// Everything the Training tab shows, from the workouts in Apple Health.
public struct TrainingOverview: Equatable, Sendable {
    /// Weeks in the "last weeks" chart, the current one included (inside the 90 days of Health history kept).
    public static let chartWeeks = 12
    /// Days of training sessions listed, today included.
    public static let recentDays = 28

    public struct WeekCount: Equatable, Sendable, Identifiable {
        public var weekStart: LocalDay
        public var sessions: Int

        public init(weekStart: LocalDay, sessions: Int) {
            self.weekStart = weekStart
            self.sessions = sessions
        }

        public var id: LocalDay {
            weekStart
        }
    }

    public var today: LocalDay
    public var week: TrainingWeek
    /// Training sessions per week, oldest first; the last one is the current week.
    public var weeklySessions: [WeekCount]
    /// Training sessions of the last ``recentDays`` days, newest first.
    public var recentSessions: [HealthWorkout]
    /// This week's workouts that don't count as training.
    public var activity: ActivitySummary

    /// False when Apple Health has no workout at all in the days read.
    public var hasWorkouts: Bool

    /// The first day the overview needs workouts from.
    public static func firstDay(today: LocalDay, firstWeekday: Int) -> LocalDay {
        today.weekStart(firstWeekday: firstWeekday).adding(days: -7 * (chartWeeks - 1))
    }

    /// - Parameters:
    ///   - workouts: every workout from ``firstDay(today:firstWeekday:)`` on, doubles included.
    ///   - training: the training days of the current week (for the planned days).
    ///   - firstWeekday: 1 = Sunday … 7 = Saturday, as `Calendar.firstWeekday`.
    public init(workouts: [HealthWorkout], rules: TrainingRules, training: TrainingDays, today: LocalDay, firstWeekday: Int) {
        self.today = today
        let sessions = WorkoutSessions.merged(workouts, rules: rules)
        let trained = sessions.filter(rules.countsAsTraining)
        let weekStart = today.weekStart(firstWeekday: firstWeekday)
        let byDay = Dictionary(grouping: trained, by: \.day)
        week = TrainingWeek(days: (0 ..< 7).map { offset in
            let day = weekStart.adding(days: offset)
            return TrainingWeek.Day(day: day, sessions: byDay[day] ?? [], isPlanned: training.isPlanned(day))
        })
        let byWeek = Dictionary(grouping: trained) { $0.day.weekStart(firstWeekday: firstWeekday) }
        weeklySessions = (0 ..< Self.chartWeeks).reversed().map { back in
            let start = weekStart.adding(days: -7 * back)
            return WeekCount(weekStart: start, sessions: byWeek[start]?.count ?? 0)
        }
        let recentStart = today.adding(days: -(Self.recentDays - 1))
        recentSessions = trained.filter { $0.day >= recentStart }.reversed()
        activity = ActivitySummary(
            workouts: sessions.filter { !rules.countsAsTraining($0) && $0.day >= weekStart }.reversed(),
        )
        hasWorkouts = !workouts.isEmpty
    }
}
