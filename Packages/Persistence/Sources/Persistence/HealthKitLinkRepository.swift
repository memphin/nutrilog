import Core
import Foundation
import GRDB

/// The tables whose rows Vitalion mirrors to Apple Health (`healthkit_link.owner_table`).
public enum HealthKitOwner: String, Codable, Hashable, Sendable, CaseIterable, DatabaseValueConvertible {
    case diaryEntry = "diary_entry"
    case waterEntry = "water_entry"
    case weightEntry = "weight_entry"
}

/// One Health sample Vitalion wrote for one of its rows (`healthkit_link`).
public struct HealthKitLink: Codable, Hashable, Identifiable, Sendable, TimestampedRecord {
    public static let databaseTableName = "healthkit_link"

    public var id: String
    public var ownerTable: HealthKitOwner
    public var ownerID: String
    /// The HealthKit type identifier, e.g. "HKQuantityTypeIdentifierDietaryProtein".
    public var hkType: String
    /// `HKObject.uuid`.
    public var hkUUID: String
    public var createdAt: Date

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case ownerTable = "owner_table"
        case ownerID = "owner_id"
        case hkType = "hk_type"
        case hkUUID = "hk_uuid"
        case createdAt = "created_at"
    }

    public typealias Columns = CodingKeys

    public init(id: String = newID(), ownerTable: HealthKitOwner, ownerID: String, hkType: String, hkUUID: String, createdAt: Date) {
        self.id = id
        self.ownerTable = ownerTable
        self.ownerID = ownerID
        self.hkType = hkType
        self.hkUUID = hkUUID
        self.createdAt = createdAt
    }
}

/// A row whose Health copy must be brought up to date (`healthkit_outbox`): written when the row is active,
/// deleted when it is soft-deleted or gone.
public struct HealthKitOutboxItem: Codable, Hashable, Sendable, TimestampedRecord {
    public static let databaseTableName = "healthkit_outbox"

    public var ownerTable: HealthKitOwner
    public var ownerID: String
    /// A new value of a monotonic counter on every (re)queue; `complete` only removes the row when nothing re-queued it.
    public var generation: Int
    /// Attempts started since the row was last queued (counted before each try, see `markAttempt`).
    public var attempts: Int
    public var lastError: String?
    public var queuedAt: Date

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case generation, attempts
        case ownerTable = "owner_table"
        case ownerID = "owner_id"
        case lastError = "last_error"
        case queuedAt = "queued_at"
    }

    public typealias Columns = CodingKeys
}

/// A Vitalion row with Health samples whose row is soft-deleted or missing (orphan cleanup).
public struct HealthKitOrphan: Hashable, Sendable {
    public var ownerTable: HealthKitOwner
    public var ownerID: String
    /// The `hk_type` of each linked sample.
    public var hkTypes: Set<String>
}

/// `healthkit_link` and the `healthkit_outbox` queue (backlog #27).
///
/// The repositories that change mirrored rows (`DiaryRepository`, `WaterRepository`, `WeightRepository`) queue them in the same
/// transaction as the change; the app's Health writer drains the queue after the commit.
public struct HealthKitLinkRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Links

    public func links(for owner: HealthKitOwner, id: String) throws -> [HealthKitLink] {
        try database.reader.read { db in
            try HealthKitLink
                .filter(HealthKitLink.Columns.ownerTable == owner && HealthKitLink.Columns.ownerID == id)
                .order(HealthKitLink.Columns.hkType)
                .fetchAll(db)
        }
    }

    /// Replaces the links of a row with the samples just written for it (`hkType`, `hkUUID`). With `types` (hk_type
    /// identifiers), only links of those types are replaced: links of types the app may not touch right now (write
    /// permission withdrawn) keep describing the samples still in Health.
    public func replaceLinks(
        for owner: HealthKitOwner, id: String, types: Set<String>? = nil, with samples: [(hkType: String, hkUUID: String)],
    ) throws {
        let now = clock.now()
        try database.writer.write { db in
            try Self.deleteLinks(db, owner: owner, id: id, types: types)
            for sample in samples {
                try HealthKitLink(ownerTable: owner, ownerID: id, hkType: sample.hkType, hkUUID: sample.hkUUID, createdAt: now)
                    .insert(db)
            }
        }
    }

    /// Deletes the links of a row (only those of `types` when given).
    public func deleteLinks(for owner: HealthKitOwner, id: String, types: Set<String>? = nil) throws {
        try database.writer.write { db in try Self.deleteLinks(db, owner: owner, id: id, types: types) }
    }

    /// Rows that still have Health samples although they were deleted (soft or hard).
    public func orphans() throws -> [HealthKitOrphan] {
        try database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT l.owner_table, l.owner_id, l.hk_type FROM healthkit_link l
            WHERE NOT EXISTS (
                SELECT 1 FROM diary_entry o WHERE l.owner_table = 'diary_entry' AND o.id = l.owner_id AND o.deleted_at IS NULL
                UNION ALL
                SELECT 1 FROM water_entry o WHERE l.owner_table = 'water_entry' AND o.id = l.owner_id AND o.deleted_at IS NULL
                UNION ALL
                SELECT 1 FROM weight_entry o WHERE l.owner_table = 'weight_entry' AND o.id = l.owner_id AND o.deleted_at IS NULL
            )
            ORDER BY l.owner_table, l.owner_id, l.hk_type
            """)
            var result: [HealthKitOrphan] = []
            for row in rows {
                let owner: HealthKitOwner = row["owner_table"]
                let id: String = row["owner_id"]
                let type: String = row["hk_type"]
                if result.last?.ownerTable == owner, result.last?.ownerID == id {
                    result[result.count - 1].hkTypes.insert(type)
                } else {
                    result.append(HealthKitOrphan(ownerTable: owner, ownerID: id, hkTypes: [type]))
                }
            }
            return result
        }
    }

    // MARK: Outbox

    /// Queues a row (also re-queues a pending or failed one, resetting its attempts).
    public func enqueue(_ owner: HealthKitOwner, id: String) throws {
        let now = clock.now()
        try database.writer.write { db in try Self.enqueue(db, owner: owner, ids: [id], now: now) }
    }

    /// Queued rows, oldest first.
    public func pending() throws -> [HealthKitOutboxItem] {
        try database.reader.read { db in
            try HealthKitOutboxItem.order(HealthKitOutboxItem.Columns.generation).fetchAll(db)
        }
    }

    /// Removes a handled row, unless it was queued again meanwhile (then it stays for the next pass).
    public func complete(_ item: HealthKitOutboxItem) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM healthkit_outbox WHERE owner_table = ? AND owner_id = ? AND generation = ?",
                arguments: [item.ownerTable, item.ownerID, item.generation],
            )
        }
    }

    /// Counts an attempt *before* it starts, so even a crash mid-write shows up as an attempt: the next try then uses
    /// a higher sync version and knows samples may exist. Returns the updated item, or nil when the row was
    /// completed, discarded or queued again meanwhile.
    public func markAttempt(_ item: HealthKitOutboxItem) throws -> HealthKitOutboxItem? {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE healthkit_outbox SET attempts = attempts + 1
                WHERE owner_table = ? AND owner_id = ? AND generation = ?
                """,
                arguments: [item.ownerTable, item.ownerID, item.generation],
            )
            guard db.changesCount > 0 else { return nil }
            var updated = item
            updated.attempts += 1
            return updated
        }
    }

    /// Keeps a row for the next try and records why it failed (the attempt was counted by `markAttempt`).
    public func recordFailure(_ item: HealthKitOutboxItem, error: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE healthkit_outbox SET last_error = ?
                WHERE owner_table = ? AND owner_id = ? AND generation = ?
                """,
                arguments: [error, item.ownerTable, item.ownerID, item.generation],
            )
        }
    }

    /// Empties the queue (writing to Health was turned off).
    public func discardPending() throws {
        try database.writer.write { db in _ = try HealthKitOutboxItem.deleteAll(db) }
    }

    /// Queues the active diary, water and weight entries from day `since` on that have no Health samples yet — after
    /// write permission was granted, so entries logged shortly before (onboarding skipped, access granted later) are
    /// written without a full backfill. Weights count from `since`'s midnight in `calendar`. Returns the number queued.
    @discardableResult
    public func enqueueUnlinked(since day: LocalDay, calendar: Calendar = .current) throws -> Int {
        let now = clock.now()
        let start = Timestamp.string(day.startDate(calendar: calendar))
        return try database.writer.write { db in
            var count = 0
            for owner in HealthKitOwner.allCases {
                let isWeight = owner == .weightEntry
                let ids = try String.fetchAll(db, sql: """
                SELECT o.id FROM \(owner.rawValue) o
                WHERE o.deleted_at IS NULL AND \(isWeight ? "o.measured_at" : "o.day") >= ?
                AND NOT EXISTS (SELECT 1 FROM healthkit_link l WHERE l.owner_table = ? AND l.owner_id = o.id)
                ORDER BY \(isWeight ? "o.measured_at" : "o.day"), o.id
                """, arguments: [isWeight ? start : day.isoString, owner])
                try Self.enqueue(db, owner: owner, ids: ids, now: now)
                count += ids.count
            }
            return count
        }
    }

    /// Queues active weights from `since`'s midnight (in `calendar`) that have body fat but no linked sample of
    /// `hkType` (the body-fat type) — after body fat writing was allowed, so weights written before get their body fat
    /// sample. Returns the number queued.
    @discardableResult
    public func enqueueWeights(missing hkType: String, since day: LocalDay, calendar: Calendar = .current) throws -> Int {
        let now = clock.now()
        let start = Timestamp.string(day.startDate(calendar: calendar))
        return try database.writer.write { db in
            let ids = try String.fetchAll(db, sql: """
            SELECT o.id FROM weight_entry o
            WHERE o.deleted_at IS NULL AND o.body_fat_pct IS NOT NULL AND o.measured_at >= ?
            AND NOT EXISTS (
                SELECT 1 FROM healthkit_link l WHERE l.owner_table = 'weight_entry' AND l.owner_id = o.id AND l.hk_type = ?
            )
            ORDER BY o.measured_at, o.id
            """, arguments: [start, hkType])
            try Self.enqueue(db, owner: .weightEntry, ids: ids, now: now)
            return ids.count
        }
    }

    /// Emits the generation counter now and whenever a row is queued. Completing, failing or discarding rows never
    /// changes it, so a drain triggered by this never re-triggers itself.
    public func observeQueue() -> AsyncValueObservation<Int?> {
        ValueObservation
            .tracking { db in try Int.fetchOne(db, sql: "SELECT value FROM healthkit_outbox_sequence WHERE id = 1") }
            .removeDuplicates()
            .values(in: database.reader)
    }

    /// Emits the queued rows (pending and failed) now and after every change — for a "waiting to be written" hint.
    public func observePending() -> AsyncValueObservation<[HealthKitOutboxItem]> {
        ValueObservation
            .tracking { db in try HealthKitOutboxItem.order(HealthKitOutboxItem.Columns.generation).fetchAll(db) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    // MARK: Helpers

    static func deleteLinks(_ db: Database, owner: HealthKitOwner, id: String, types: Set<String>? = nil) throws {
        var request = HealthKitLink.filter(HealthKitLink.Columns.ownerTable == owner && HealthKitLink.Columns.ownerID == id)
        if let types {
            request = request.filter(types.contains(HealthKitLink.Columns.hkType))
        }
        try request.deleteAll(db)
    }

    /// Queues rows inside the caller's transaction. Each (re)queue takes a new value of the monotonic counter.
    static func enqueue(_ db: Database, owner: HealthKitOwner, ids: [String], now: Date) throws {
        for id in ids {
            try db.execute(sql: "UPDATE healthkit_outbox_sequence SET value = value + 1 WHERE id = 1")
            try db.execute(
                sql: """
                INSERT INTO healthkit_outbox (owner_table, owner_id, generation, attempts, last_error, queued_at)
                VALUES (?, ?, (SELECT value FROM healthkit_outbox_sequence WHERE id = 1), 0, NULL, ?)
                ON CONFLICT (owner_table, owner_id) DO UPDATE SET
                    generation = excluded.generation, attempts = 0, last_error = NULL, queued_at = excluded.queued_at
                """,
                arguments: [owner, id, Timestamp.string(now)],
            )
        }
    }

    /// Import support: queues every diary / water / weight row that has Health samples (call before a replace wipes
    /// the links, so samples of rows the backup doesn't have are deleted).
    static func enqueueLinkedOwners(_ db: Database, now: Date) throws {
        for owner in HealthKitOwner.allCases {
            let ids = try String.fetchAll(
                db, sql: "SELECT DISTINCT owner_id FROM healthkit_link WHERE owner_table = ? ORDER BY owner_id", arguments: [owner],
            )
            try enqueue(db, owner: owner, ids: ids, now: now)
        }
    }

    /// Import support: queues every active diary / water / weight row (after a replace import).
    static func enqueueActiveOwners(_ db: Database, now: Date) throws {
        for owner in HealthKitOwner.allCases {
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM \(owner.rawValue) WHERE deleted_at IS NULL ORDER BY id",
            )
            try enqueue(db, owner: owner, ids: ids, now: now)
        }
    }
}
