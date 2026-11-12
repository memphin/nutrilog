import Core
import Foundation
import GRDB

/// Water logged in Vitalion (`water_entry`, FR-46). Water logged by other apps is read from Health into
/// `daily_metrics.water_ml` (which leaves out Vitalion's own Health samples); the day's total is the sum of both.
public struct WaterEntry: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "water_entry"

    public var id: String
    public var day: LocalDay
    public var loggedAt: Date
    public var ml: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, ml, revision
        case loggedAt = "logged_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

/// Water entries: add, soft delete with undo, per-day lists and totals (backlog #27; UI in #29). Every change is
/// queued for the Apple Health writer in the same transaction (`healthkit_outbox`).
public struct WaterRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Logs `ml` on `day`, timestamped now (or `loggedAt`).
    @discardableResult
    public func add(ml: Double, day: LocalDay, loggedAt: Date? = nil) throws -> WaterEntry {
        guard ml > 0, ml.isFinite else { throw PersistenceError.amountNotPositive }
        try EntryLimits.validate(amount: ml)
        let now = clock.now()
        return try database.writer.write { db in
            let entry = WaterEntry(
                id: newID(), day: day, loggedAt: loggedAt ?? now, ml: ml,
                createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            )
            try entry.insert(db)
            try HealthKitLinkRepository.enqueue(db, owner: .waterEntry, ids: [entry.id], now: now)
            return entry
        }
    }

    public func entry(id: String) throws -> WaterEntry? {
        try database.reader.read { db in try WaterEntry.fetchOne(db, key: id) }
    }

    /// The day's active entries, oldest first.
    public func entries(for day: LocalDay) throws -> [WaterEntry] {
        try database.reader.read { db in try Self.request(day).fetchAll(db) }
    }

    /// The day's water logged in Vitalion, in ml.
    public func totalMl(for day: LocalDay) throws -> Double {
        try entries(for: day).reduce(0) { $0 + $1.ml }
    }

    public func observeEntries(for day: LocalDay) -> AsyncValueObservation<[WaterEntry]> {
        ValueObservation.tracking { db in try Self.request(day).fetchAll(db) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    /// Active entries of every day in `days`, oldest first: one observation for a multi-day view (the dashboard's
    /// 7-day water trend and today's entries).
    public func observeEntries(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[WaterEntry]> {
        ValueObservation.tracking { db in
            try WaterEntry
                .filter(WaterEntry.Columns.day >= days.lowerBound && WaterEntry.Columns.day <= days.upperBound)
                .filter(WaterEntry.Columns.deletedAt == nil)
                .order(WaterEntry.Columns.day, WaterEntry.Columns.loggedAt, WaterEntry.Columns.id)
                .fetchAll(db)
        }
        .removeDuplicates()
        .values(in: database.reader)
    }

    public func softDelete(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            var changed: [String] = []
            for id in ids {
                guard var entry = try WaterEntry.fetchOne(db, key: id), entry.deletedAt == nil else { continue }
                entry.stampDeleted(now)
                try entry.update(db)
                changed.append(id)
            }
            try HealthKitLinkRepository.enqueue(db, owner: .waterEntry, ids: changed, now: now)
        }
    }

    /// Undo for `softDelete`.
    public func restore(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            var changed: [String] = []
            for id in ids {
                guard var entry = try WaterEntry.fetchOne(db, key: id), entry.deletedAt != nil else { continue }
                entry.deletedAt = nil
                entry.stampUpdated(now)
                try entry.update(db)
                changed.append(id)
            }
            try HealthKitLinkRepository.enqueue(db, owner: .waterEntry, ids: changed, now: now)
        }
    }

    private static func request(_ day: LocalDay) -> QueryInterfaceRequest<WaterEntry> {
        WaterEntry
            .filter(WaterEntry.Columns.day == day && WaterEntry.Columns.deletedAt == nil)
            .order(WaterEntry.Columns.loggedAt, WaterEntry.Columns.id)
    }
}
