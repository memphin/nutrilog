import Core
import Foundation
import GRDB

/// A row of `health_workout`: one workout read from Apple Health (Core `HealthWorkout`).
public struct WorkoutRecord: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "health_workout"

    public var id: String
    public var day: LocalDay
    public var activityType: Int
    public var startAt: Date
    public var endAt: Date
    public var durationSec: Double
    public var activeKcal: Double?
    public var distanceM: Double?
    public var sourceName: String
    public var sourceBundleID: String
    public var sourceProductType: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, revision
        case activityType = "activity_type"
        case startAt = "start_at"
        case endAt = "end_at"
        case durationSec = "duration_sec"
        case activeKcal = "active_kcal"
        case distanceM = "distance_m"
        case sourceName = "source_name"
        case sourceBundleID = "source_bundle_id"
        case sourceProductType = "source_product_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(_ workout: HealthWorkout, now: Date) {
        id = workout.id
        day = workout.day
        activityType = workout.activityType
        startAt = workout.start
        endAt = workout.end
        durationSec = workout.durationSec
        activeKcal = workout.activeKcal
        distanceM = workout.distanceM
        sourceName = workout.source.name
        sourceBundleID = workout.source.bundleIdentifier
        sourceProductType = workout.source.productType
        createdAt = now
        updatedAt = now
        deletedAt = nil
        revision = 1
    }

    public var workout: HealthWorkout {
        HealthWorkout(
            id: id, day: day, activityType: activityType, start: startAt, end: endAt, durationSec: durationSec,
            activeKcal: activeKcal, distanceM: distanceM,
            source: HealthSource(name: sourceName, bundleIdentifier: sourceBundleID, productType: sourceProductType),
        )
    }

    /// Whether `workout` is what this row already holds. Stored timestamps keep milliseconds and don't parse back
    /// bit for bit, so times that differ only by that rounding are the same (else every sync would be a change).
    func holds(_ workout: HealthWorkout) -> Bool {
        func same(_ lhs: Date, _ rhs: Date) -> Bool {
            abs(lhs.timeIntervalSince(rhs)) < 0.002
        }
        return deletedAt == nil && day == workout.day && activityType == workout.activityType
            && same(startAt, workout.start) && same(endAt, workout.end) && durationSec == workout.durationSec
            && activeKcal == workout.activeKcal && distanceM == workout.distanceM && sourceName == workout.source.name
            && sourceBundleID == workout.source.bundleIdentifier && sourceProductType == workout.source.productType
    }
}

/// One entry of the "counts as training" history in the `setting` table (Core `TrainingRules`).
struct TrainingRulesEntry: Codable, Equatable, Sendable {
    /// The first day the choice applies to.
    var from: LocalDay
    /// `WorkoutKind` raw values that don't count as training.
    var excluded: [Int]
}

/// The workouts read from Apple Health (`health_workout`) and which kinds of them count as training (`TrainingRules`,
/// kept in the `setting` table so it is part of exports and backups).
public struct WorkoutRepository: Sendable {
    /// `[TrainingRulesEntry]`: the kinds that don't count as training, as history.
    static let rulesSettingKey = "trainingWorkoutRules"

    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Workouts

    /// Makes the stored workouts that started in `interval` match `workouts`, which is everything Apple Health has for
    /// it: new ones are inserted, changed ones updated, and stored ones Health no longer has are deleted (a
    /// tombstone). Workouts outside `interval` are left alone. Only rows that changed get a new `updated_at` /
    /// `revision`. Returns the number of rows inserted, changed or deleted.
    @discardableResult
    public func reconcile(_ workouts: [HealthWorkout], in interval: DateInterval) throws -> Int {
        let now = clock.now()
        return try database.writer.write { db in
            var changed = 0
            for workout in workouts {
                if let existing = try WorkoutRecord.fetchOne(db, key: workout.id) {
                    guard !existing.holds(workout) else { continue }
                    // Also brings back a workout that was gone from Health for a while (a tombstone).
                    var updated = WorkoutRecord(workout, now: now)
                    updated.createdAt = existing.createdAt
                    updated.revision = existing.revision
                    updated.stampUpdated(now)
                    try updated.update(db)
                } else {
                    try WorkoutRecord(workout, now: now).insert(db)
                }
                changed += 1
            }
            let kept = Set(workouts.map(\.id))
            let stored = try WorkoutRecord
                .filter(WorkoutRecord.Columns.deletedAt == nil)
                .filter(WorkoutRecord.Columns.startAt >= Timestamp.string(interval.start))
                .filter(WorkoutRecord.Columns.startAt < Timestamp.string(interval.end))
                .fetchAll(db)
            for var record in stored where !kept.contains(record.id) {
                record.stampDeleted(now)
                try record.update(db)
                changed += 1
            }
            return changed
        }
    }

    /// The workouts that started on `days`, oldest first (doubles included: see Core `WorkoutSessions`).
    public func workouts(in days: ClosedRange<LocalDay>) throws -> [HealthWorkout] {
        try database.reader.read { db in try Self.request(days).fetchAll(db).map(\.workout) }
    }

    /// ``workouts(in:)`` now and after every change (a Health sync).
    public func observeWorkouts(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[HealthWorkout]> {
        database.observe { db in try Self.request(days).fetchAll(db).map(\.workout) }
    }

    /// The newest workout that started on `days`; nil when there is none.
    public func latestWorkout(in days: ClosedRange<LocalDay>) throws -> HealthWorkout? {
        try database.reader.read { db in try Self.request(days).reversed().fetchOne(db)?.workout }
    }

    /// The kinds of every stored workout, each once, by name.
    public func kinds() throws -> [WorkoutKind] {
        let types = try database.reader.read { db in
            try Int.fetchAll(db, sql: "SELECT DISTINCT activity_type FROM health_workout WHERE deleted_at IS NULL")
        }
        return Set(types.map(WorkoutKind.init(activityType:))).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: What counts as training

    public func rules() throws -> TrainingRules {
        try database.reader.read { db in try Self.rules(db) }
    }

    /// ``rules()`` now and after every change.
    public func observeRules() -> AsyncValueObservation<TrainingRules> {
        database.observe { db in try Self.rules(db) }
    }

    /// The kinds in `excluded` don't count as training from `day` on (a choice already starting that day is replaced);
    /// earlier days keep theirs. Returns the rules now in effect.
    @discardableResult
    public func setExcluded(_ excluded: Set<WorkoutKind>, from day: LocalDay) throws -> TrainingRules {
        let now = clock.now()
        return try database.writer.write { db in
            var entries = try Self.entries(db).filter { $0.from != day }
            let value = excluded.map(\.rawValue).sorted()
            // The same choice as the one before it is no change (and must not move the day the rules started).
            if let previous = entries.last(where: { $0.from < day }), previous.excluded == value {
                try Self.save(db, entries, now: now)
                return try Self.rules(db)
            }
            entries.append(TrainingRulesEntry(from: day, excluded: value))
            try Self.save(db, entries.sorted { $0.from < $1.from }, now: now)
            return try Self.rules(db)
        }
    }

    /// Starts the rules on `day` with the default kinds, unless they already started. From then on a workout that
    /// counts as training makes its day a training day; earlier days keep the status they had.
    public func startRulesIfNeeded(from day: LocalDay) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard try Self.entries(db).isEmpty else { return }
            let entry = TrainingRulesEntry(from: day, excluded: TrainingRules.defaultExcluded.map(\.rawValue).sorted())
            try Self.save(db, [entry], now: now)
        }
    }

    // MARK: Helpers

    static func request(_ days: ClosedRange<LocalDay>) -> QueryInterfaceRequest<WorkoutRecord> {
        WorkoutRecord
            .filter(WorkoutRecord.Columns.deletedAt == nil)
            .filter(WorkoutRecord.Columns.day >= days.lowerBound && WorkoutRecord.Columns.day <= days.upperBound)
            .order(WorkoutRecord.Columns.startAt, WorkoutRecord.Columns.id)
    }

    static func entries(_ db: Database) throws -> [TrainingRulesEntry] {
        // An unreadable value counts as no choice: the default kinds.
        (try? ProfileRepository.setting(db, rulesSettingKey, as: [TrainingRulesEntry].self)) ?? []
    }

    static func save(_ db: Database, _ entries: [TrainingRulesEntry], now: Date) throws {
        let json = try String(decoding: JSONEncoder().encode(entries), as: UTF8.self)
        try SettingRow(key: rulesSettingKey, value: json, updatedAt: now).save(db)
    }

    static func rules(_ db: Database) throws -> TrainingRules {
        let choices = try entries(db).map { ($0.from, Set($0.excluded.compactMap(WorkoutKind.init(rawValue:)))) }
        return TrainingRules(Dictionary(choices) { _, later in later })
    }

    /// The days of `days` that a training workout makes a training day (`TrainingRules.trainingDays(of:)`).
    static func trainingDays(_ db: Database, in days: ClosedRange<LocalDay>) throws -> Set<LocalDay> {
        let rules = try rules(db)
        // Before the rules started no workout decides a day: skip the read (every install without Health).
        guard let start = rules.timeline.first?.from, start <= days.upperBound else { return [] }
        return try rules.trainingDays(of: request(max(start, days.lowerBound) ... days.upperBound).fetchAll(db).map(\.workout))
    }
}
