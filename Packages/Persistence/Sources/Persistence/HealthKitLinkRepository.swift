import Core
import Foundation
import GRDB

/// The tables whose rows Nutrilog mirrors to Apple Health (`healthkit_link.owner_table`).
public enum HealthKitOwner: String, Codable, Hashable, Sendable, CaseIterable, DatabaseValueConvertible {
    case diaryEntry = "diary_entry"
    case waterEntry = "water_entry"
    case weightEntry = "weight_entry"
}

/// One Health sample Nutrilog wrote for one of its rows (`healthkit_link`).
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
    /// Grows on every (re)queue; `complete` only removes the row when nothing re-queued it meanwhile.
    public var generation: Int
    /// Failed attempts since the row was last queued.
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

/// A Nutrilog row with Health samples whose row is soft-deleted or missing (orphan cleanup).
public struct HealthKitOrphan: Hashable, Sendable {
    public var ownerTable: HealthKitOwner
    public var ownerID: String
    /// The `hk_type` of each linked sample.
    public var hkTypes: Set<String>
}

/// `healthkit_link` and the `healthkit_outbox` queue (backlog #27).
///
/// The repositories that change mirrored rows (`DiaryRepository`, `WaterRepository`) queue them in the same
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

    /// Replaces the links of a row with the samples just written for it (`hkType`, `hkUUID`).
    public func replaceLinks(for owner: HealthKitOwner, id: String, with samples: [(hkType: String, hkUUID: String)]) throws {
        let now = clock.now()
        try database.writer.write { db in
            try Self.deleteLinks(db, owner: owner, id: id)
            for sample in samples {
                try HealthKitLink(ownerTable: owner, ownerID: id, hkType: sample.hkType, hkUUID: sample.hkUUID, createdAt: now)
                    .insert(db)
            }
        }
    }

    public func deleteLinks(for owner: HealthKitOwner, id: String) throws {
        try database.writer.write { db in try Self.deleteLinks(db, owner: owner, id: id) }
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

    /// Keeps a row for the next try and records why it failed.
    public func recordFailure(_ item: HealthKitOutboxItem, error: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE healthkit_outbox SET attempts = attempts + 1, last_error = ?
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

    /// Emits the newest generation now and whenever a row is queued (nil when the queue is empty). Completing or
    /// failing a row does not change it, so a drain triggered by this never re-triggers itself.
    public func observeQueue() -> AsyncValueObservation<Int?> {
        ValueObservation
            .tracking { db in try Int.fetchOne(db, sql: "SELECT MAX(generation) FROM healthkit_outbox") }
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

    static func deleteLinks(_ db: Database, owner: HealthKitOwner, id: String) throws {
        try HealthKitLink.filter(HealthKitLink.Columns.ownerTable == owner && HealthKitLink.Columns.ownerID == id).deleteAll(db)
    }

    /// Queues rows inside the caller's transaction.
    static func enqueue(_ db: Database, owner: HealthKitOwner, ids: [String], now: Date) throws {
        for id in ids {
            try db.execute(
                sql: """
                INSERT INTO healthkit_outbox (owner_table, owner_id, generation, attempts, last_error, queued_at)
                VALUES (?, ?, (SELECT COALESCE(MAX(generation), 0) + 1 FROM healthkit_outbox), 0, NULL, ?)
                ON CONFLICT (owner_table, owner_id) DO UPDATE SET
                    generation = excluded.generation, attempts = 0, last_error = NULL, queued_at = excluded.queued_at
                """,
                arguments: [owner, id, Timestamp.string(now)],
            )
        }
    }
}
