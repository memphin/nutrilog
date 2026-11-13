import Core
import Foundation
import GRDB

/// A row of `training_schedule`: the default training weekdays and boost from `effectiveFrom` on (Core
/// `TrainingSchedule`).
public struct TrainingScheduleRecord: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "training_schedule"

    public var id: String
    public var effectiveFrom: LocalDay
    /// Sorted `Calendar.weekday` numbers as a JSON array, e.g. "[2,4,6]".
    public var weekdaysJSON: String
    public var boostPercent: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, revision
        case effectiveFrom = "effective_from"
        case weekdaysJSON = "weekdays_json"
        case boostPercent = "boost_percent"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(id: String = newID(), schedule: TrainingSchedule) {
        self.id = id
        effectiveFrom = schedule.effectiveFrom
        weekdaysJSON = Self.json(schedule.weekdays)
        boostPercent = schedule.boostPercent
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }

    /// The training weekdays; an unreadable value counts as none.
    public var weekdays: Set<Int> {
        let decoded = try? JSONDecoder().decode([Int].self, from: Data(weekdaysJSON.utf8))
        return Set(decoded ?? [])
    }

    public var schedule: TrainingSchedule {
        TrainingSchedule(effectiveFrom: effectiveFrom, weekdays: weekdays, boostPercent: boostPercent)
    }

    static func json(_ weekdays: Set<Int>) -> String {
        "[" + weekdays.sorted().map(String.init).joined(separator: ",") + "]"
    }
}

/// A row of `training_day`: a day the user switched on or off as a training day, whatever its weekday.
public struct TrainingDayOverride: Codable, Hashable, Sendable, SyncedRecord {
    public static let databaseTableName = "training_day"

    public var day: LocalDay
    public var isTraining: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case day, revision
        case isTraining = "is_training"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

public extension Target {
    /// This target on a training day boosted by `percent` (Core `TrainingBoost`): more calories as extra carbs;
    /// protein, fat and fiber unchanged. 0 % returns the target unchanged.
    func boosted(byPercent percent: Int) -> Target {
        var boosted = self
        (boosted.kcal, boosted.carbsG) = TrainingBoost.apply(kcal: kcal, carbsG: carbsG, percent: percent)
        return boosted
    }
}

public extension TrainingDays {
    /// The target that applies on `day`: `base` (the target in effect that day, `ProfileRepository.target(on:)`),
    /// boosted by the day's boost on a training day. The one rule every screen judging a day's intake uses; the
    /// weekly check-in and the adaptive estimate stay on the base target.
    func effectiveTarget(_ base: Target?, on day: LocalDay) -> Target? {
        guard let base, let boost = boost(on: day) else { return base }
        return base.boosted(byPercent: boost)
    }
}

/// Training days: the default weekdays and boost as history (`training_schedule`, like `target`) and per-day
/// overrides (`training_day`). ``trainingDays(in:)`` / ``observeTrainingDays(in:)`` combine both into a Core
/// `TrainingDays` resolver.
public struct TrainingDayRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Schedule

    /// Sets the training weekdays (1 = Sunday … 7 = Saturday) and boost from `effectiveFrom` on. A schedule already
    /// starting that day is replaced in place; earlier schedules stay untouched, so past days keep their training
    /// days and boost. Throws a validation error for a boost outside `TrainingSchedule.boostPercentRange` or a weekday
    /// outside 1…7.
    @discardableResult
    public func setSchedule(weekdays: Set<Int>, boostPercent: Int, effectiveFrom: LocalDay) throws -> TrainingSchedule {
        guard TrainingSchedule.boostPercentRange.contains(boostPercent) else {
            throw PersistenceError.validation(String(localized: "boost must be between 0 and 100 percent", bundle: .module))
        }
        guard weekdays.allSatisfy({ (1 ... 7).contains($0) }) else {
            throw PersistenceError.validation(String(localized: "weekday must be between 1 and 7", bundle: .module))
        }
        let schedule = TrainingSchedule(effectiveFrom: effectiveFrom, weekdays: weekdays, boostPercent: boostPercent)
        let now = clock.now()
        try database.writer.write { db in
            if var existing = try TrainingScheduleRecord
                .filter(TrainingScheduleRecord.Columns.effectiveFrom == effectiveFrom)
                .filter(TrainingScheduleRecord.Columns.deletedAt == nil)
                .fetchOne(db)
            {
                guard existing.schedule != schedule else { return }
                existing.weekdaysJSON = TrainingScheduleRecord.json(schedule.weekdays)
                existing.boostPercent = schedule.boostPercent
                existing.stampUpdated(now)
                try existing.update(db)
            } else {
                var record = TrainingScheduleRecord(schedule: schedule)
                record.stampCreated(now)
                try record.insert(db)
            }
        }
        return schedule
    }

    /// The schedule in effect on `day`: the latest one starting on or before it; nil before the first.
    public func schedule(on day: LocalDay) throws -> TrainingSchedule? {
        try database.reader.read { db in try Self.schedule(db, on: day) }
    }

    // MARK: Overrides

    /// The user's tap on a day's training switch (diary, meal plan, history calendar): flips whether `day` is a
    /// training day. The choice is kept as an override only while it differs from the day's schedule; a day switched
    /// back to what its schedule says follows the schedule again. Returns whether `day` is a training day now.
    @discardableResult
    public func toggleTraining(on day: LocalDay) throws -> Bool {
        let now = clock.now()
        return try database.writer.write { db in
            let days = try Self.trainingDays(db, in: day ... day)
            let isTraining = !days.isTraining(day)
            if isTraining == days.scheduledTraining(day) {
                try Self.clearOverride(db, on: day, now: now)
            } else {
                try Self.setTraining(db, isTraining, on: day, now: now)
            }
            return isTraining
        }
    }

    // MARK: Resolver

    /// Every schedule and the overrides of `days`. Only answers days in `days` correctly: overrides outside it are
    /// not loaded.
    public func trainingDays(in days: ClosedRange<LocalDay>) throws -> TrainingDays {
        try database.reader.read { db in try Self.trainingDays(db, in: days) }
    }

    /// ``trainingDays(in:)`` now and after every change to a schedule or an override — for the dashboard, diary and
    /// history, which must follow the settings live.
    public func observeTrainingDays(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<TrainingDays> {
        database.observe { db in try Self.trainingDays(db, in: days) }
    }

    /// The target that applies on `day` (``TrainingDays/effectiveTarget(_:on:)``): the one in effect then, boosted on a
    /// training day. For a one-off read (widget, Siri); screens that follow changes observe the target and the
    /// training days.
    public func effectiveTarget(on day: LocalDay) throws -> Target? {
        try database.reader.read { db in
            try Self.trainingDays(db, in: day ... day).effectiveTarget(ProfileRepository.target(db, on: day), on: day)
        }
    }

    // MARK: Helpers

    static func scheduleHistory(_ db: Database) throws -> [TrainingScheduleRecord] {
        try TrainingScheduleRecord
            .filter(TrainingScheduleRecord.Columns.deletedAt == nil)
            .order(TrainingScheduleRecord.Columns.effectiveFrom.desc)
            .fetchAll(db)
    }

    static func timeline(_ db: Database) throws -> EffectiveTimeline<TrainingSchedule> {
        try EffectiveTimeline(scheduleHistory(db).map { (from: $0.effectiveFrom, value: $0.schedule) })
    }

    static func schedule(_ db: Database, on day: LocalDay) throws -> TrainingSchedule? {
        try TrainingScheduleRecord
            .filter(TrainingScheduleRecord.Columns.deletedAt == nil && TrainingScheduleRecord.Columns.effectiveFrom <= day)
            .order(TrainingScheduleRecord.Columns.effectiveFrom.desc)
            .fetchOne(db)?
            .schedule
    }

    static func overrides(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [LocalDay: Bool] {
        let rows = try TrainingDayOverride
            .filter(TrainingDayOverride.Columns.day >= days.lowerBound && TrainingDayOverride.Columns.day <= days.upperBound)
            .filter(TrainingDayOverride.Columns.deletedAt == nil)
            .fetchAll(db)
        return Dictionary(rows.map { ($0.day, $0.isTraining) }) { first, _ in first }
    }

    static func trainingDays(_ db: Database, in days: ClosedRange<LocalDay>) throws -> TrainingDays {
        try TrainingDays(timeline: timeline(db), overrides: overrides(db, in: days))
    }

    static func setTraining(_ db: Database, _ isTraining: Bool, on day: LocalDay, now: Date) throws {
        if var existing = try TrainingDayOverride.fetchOne(db, key: day) {
            guard existing.isTraining != isTraining || existing.deletedAt != nil else { return }
            existing.isTraining = isTraining
            existing.deletedAt = nil
            existing.stampUpdated(now)
            try existing.update(db)
        } else {
            try TrainingDayOverride(
                day: day, isTraining: isTraining, createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            ).insert(db)
        }
    }

    static func clearOverride(_ db: Database, on day: LocalDay, now: Date) throws {
        guard var existing = try TrainingDayOverride.fetchOne(db, key: day), existing.deletedAt == nil else { return }
        existing.stampDeleted(now)
        try existing.update(db)
    }
}
