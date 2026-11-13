import Core
import Foundation
import GRDB

/// Weights entered by hand in Vitalion (`weight_entry`, FR-42; UI in backlog #29). Weights from a scale are read
/// from Health into `daily_metrics`; `WeightReconciler` merges both. Every change is queued for the Apple Health
/// writer in the same transaction (`healthkit_outbox`), like diary and water entries.
public struct WeightRepository: Sendable {
    /// Accepted range in kg.
    public static let validKg: ClosedRange<Double> = 1 ... 499
    /// Accepted body fat range in percent.
    public static let validBodyFatPct: ClosedRange<Double> = 1 ... 75

    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Saves a weigh-in measured at `measuredAt` (default now).
    @discardableResult
    public func add(kg: Double, bodyFatPct: Double? = nil, measuredAt: Date? = nil) throws -> WeightEntry {
        try Self.validate(kg: kg, bodyFatPct: bodyFatPct)
        let now = clock.now()
        return try database.writer.write { db in
            let entry = WeightEntry(
                id: newID(), measuredAt: measuredAt ?? now, kg: kg, bodyFatPct: bodyFatPct, source: "manual",
                createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            )
            try entry.insert(db)
            try HealthKitLinkRepository.enqueue(db, owner: .weightEntry, ids: [entry.id], now: now)
            return entry
        }
    }

    /// Changes a weigh-in (its Health samples are rewritten).
    @discardableResult
    public func update(id: String, kg: Double, bodyFatPct: Double?, measuredAt: Date) throws -> WeightEntry {
        try Self.validate(kg: kg, bodyFatPct: bodyFatPct)
        let now = clock.now()
        return try database.writer.write { db in
            guard var entry = try WeightEntry.fetchOne(db, key: id), entry.deletedAt == nil else {
                throw PersistenceError.notFound("weight entry \(id)")
            }
            guard entry.kg != kg || entry.bodyFatPct != bodyFatPct || entry.measuredAt != measuredAt else { return entry }
            entry.kg = kg
            entry.bodyFatPct = bodyFatPct
            entry.measuredAt = measuredAt
            entry.stampUpdated(now)
            try entry.update(db)
            try HealthKitLinkRepository.enqueue(db, owner: .weightEntry, ids: [id], now: now)
            return entry
        }
    }

    public func entry(id: String) throws -> WeightEntry? {
        try database.reader.read { db in try WeightEntry.fetchOne(db, key: id) }
    }

    /// Active entries measured in `interval` (start inclusive, end exclusive), oldest first.
    public func entries(in interval: DateInterval) throws -> [WeightEntry] {
        try database.reader.read { db in try Self.request(interval).fetchAll(db) }
    }

    public func observeEntries(in interval: DateInterval) -> AsyncValueObservation<[WeightEntry]> {
        database.observe { db in try Self.request(interval).fetchAll(db) }
    }

    /// Every active entry, newest first (`measuredAt`, then `id` descending) — not limited to a window — now and after
    /// every change (edits, deletes and undo show up while the list is open). For the weight detail's "All weigh-ins"
    /// list, which is the only place an entry older than the dashboard's window can be edited or deleted; the
    /// dashboard itself never loads it.
    public func observeAllEntries() -> AsyncValueObservation<[WeightEntry]> {
        database.observe { db in try Self.allRequest.fetchAll(db) }
    }

    public func latest() throws -> WeightEntry? {
        try database.reader.read { db in
            try WeightEntry.filter(WeightEntry.Columns.deletedAt == nil).order(WeightEntry.Columns.measuredAt.desc).fetchOne(db)
        }
    }

    public func softDelete(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            let changed = try WeightEntry.softDelete(db, ids: ids, now: now)
            try HealthKitLinkRepository.enqueue(db, owner: .weightEntry, ids: changed, now: now)
        }
    }

    /// Undo for `softDelete`.
    public func restore(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            let changed = try WeightEntry.restore(db, ids: ids, now: now)
            try HealthKitLinkRepository.enqueue(db, owner: .weightEntry, ids: changed, now: now)
        }
    }

    static func validate(kg: Double, bodyFatPct: Double?) throws {
        guard kg.isFinite, validKg.contains(kg) else {
            throw PersistenceError.validation(String(localized: "weight out of range", bundle: .module))
        }
        if let bodyFatPct {
            guard bodyFatPct.isFinite, validBodyFatPct.contains(bodyFatPct) else {
                throw PersistenceError.validation(String(localized: "body fat out of range", bundle: .module))
            }
        }
    }

    private static func request(_ interval: DateInterval) -> QueryInterfaceRequest<WeightEntry> {
        WeightEntry
            .filter(WeightEntry.Columns.deletedAt == nil)
            .filter(WeightEntry.Columns.measuredAt >= Timestamp.string(interval.start))
            .filter(WeightEntry.Columns.measuredAt < Timestamp.string(interval.end))
            .order(WeightEntry.Columns.measuredAt, WeightEntry.Columns.id)
    }

    private static var allRequest: QueryInterfaceRequest<WeightEntry> {
        WeightEntry
            .filter(WeightEntry.Columns.deletedAt == nil)
            .order(WeightEntry.Columns.measuredAt.desc, WeightEntry.Columns.id.desc)
    }
}
