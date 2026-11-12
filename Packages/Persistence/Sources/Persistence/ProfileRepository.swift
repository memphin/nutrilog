import Core
import Foundation
import GRDB

/// Profile, versioned targets, manual weights and key-value settings (backlog #11, #15).
public struct ProfileRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Profile

    public func profile() throws -> Profile {
        try database.reader.read { db in
            guard let profile = try Profile.fetchOne(db, key: 1) else { throw PersistenceError.notFound("profile") }
            return profile
        }
    }

    public func save(_ profile: Profile) throws {
        let now = clock.now()
        try database.writer.write { db in
            var updated = profile
            updated.id = 1
            let current = try Profile.fetchOne(db, key: 1)
            updated.revision = (current?.revision ?? 0) + 1
            updated.updatedAt = now
            try updated.save(db)
        }
    }

    public func observeProfile() -> AsyncValueObservation<Profile?> {
        ValueObservation.tracking { db in try Profile.fetchOne(db, key: 1) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    // MARK: Targets

    /// The target in effect on `day`: the latest row with `effective_from <= day`.
    public func target(on day: LocalDay) throws -> Target? {
        try database.reader.read { db in try Self.target(db, on: day) }
    }

    public func observeTarget(on day: LocalDay) -> AsyncValueObservation<Target?> {
        ValueObservation.tracking { db in try Self.target(db, on: day) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    /// Saves a target effective from `target.effectiveFrom`. A target already starting that day is replaced
    /// in place; earlier targets stay untouched, so past days keep their adherence (backlog #11).
    @discardableResult
    public func setTarget(_ target: Target) throws -> Target {
        let now = clock.now()
        return try database.writer.write { db in try Self.setTarget(db, target, now: now) }
    }

    static func setTarget(_ db: Database, _ target: Target, now: Date) throws -> Target {
        var saved = target
        if let existing = try Target
            .filter(Target.Columns.effectiveFrom == target.effectiveFrom && Target.Columns.deletedAt == nil)
            .fetchOne(db)
        {
            saved.id = existing.id
            saved.createdAt = existing.createdAt
            saved.revision = existing.revision
            saved.stampUpdated(now)
            try saved.update(db)
        } else {
            saved.stampCreated(now)
            try saved.insert(db)
        }
        return saved
    }

    /// Every target by its first day, to look up the one in effect on any day (history calendar, charts).
    public func targetTimeline() throws -> EffectiveTimeline<Target> {
        try EffectiveTimeline(targetHistory().map { (from: $0.effectiveFrom, value: $0) })
    }

    public func targetHistory() throws -> [Target] {
        try database.reader.read { db in
            try Target.filter(Target.Columns.deletedAt == nil).order(Target.Columns.effectiveFrom.desc).fetchAll(db)
        }
    }

    static func target(_ db: Database, on day: LocalDay) throws -> Target? {
        try Target
            .filter(Target.Columns.deletedAt == nil && Target.Columns.effectiveFrom <= day)
            .order(Target.Columns.effectiveFrom.desc)
            .fetchOne(db)
    }

    // MARK: Weight (see `WeightRepository`)

    /// A manual weigh-in (Profile & targets); queued for Apple Health like every manual weight.
    @discardableResult
    public func addWeight(kg: Double, bodyFatPct: Double? = nil, at date: Date? = nil) throws -> WeightEntry {
        try WeightRepository(database, clock: clock).add(kg: kg, bodyFatPct: bodyFatPct, measuredAt: date)
    }

    public func latestWeight() throws -> WeightEntry? {
        try WeightRepository(database, clock: clock).latest()
    }

    // MARK: Settings

    public func setting<T: Codable & Sendable>(_ key: String, as _: T.Type = T.self) throws -> T? {
        try database.reader.read { db in try Self.setting(db, key, as: T.self) }
    }

    /// Reads a setting inside a transaction the caller already holds.
    static func setting<T: Codable & Sendable>(_ db: Database, _ key: String, as _: T.Type) throws -> T? {
        guard let row = try SettingRow.fetchOne(db, key: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(row.value.utf8))
    }

    public func setSetting(_ key: String, _ value: some Codable & Sendable) throws {
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        let now = clock.now()
        try database.writer.write { db in
            try SettingRow(key: key, value: json, updatedAt: now).save(db)
        }
    }

    // MARK: Meal slots (backlog #15)

    /// Persists the given slots in this order (rename, reorder, activate/deactivate); new ids are inserted.
    public func saveMealSlots(_ slots: [MealSlot]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for (index, var slot) in slots.enumerated() {
                slot.sortOrder = index
                if let existing = try MealSlot.fetchOne(db, key: slot.id) {
                    guard existing.name != slot.name || existing.sortOrder != index || existing.isActive != slot.isActive
                        || existing.defaultStartHour != slot.defaultStartHour else { continue }
                    slot.createdAt = existing.createdAt
                    slot.revision = existing.revision
                    slot.stampUpdated(now)
                    try slot.update(db)
                } else {
                    slot.stampCreated(now)
                    try slot.insert(db)
                }
            }
        }
    }
}
