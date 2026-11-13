import Core
import Foundation
import GRDB

// MARK: - Clock

/// Injectable time source so repositories are deterministic in tests.
public struct AppClock: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    public static let system = AppClock { Date() }
}

// MARK: - Timestamps

/// ISO-8601 UTC timestamps with milliseconds, e.g. "2026-11-09T14:03:12.345Z" — the same format the
/// migrations produce with `strftime('%Y-%m-%dT%H:%M:%fZ','now')` and portable to Postgres.
public enum Timestamp {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func string(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    public static func date(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string))
    }
}

/// Records whose `Date` properties are stored as ISO-8601 TEXT.
public protocol TimestampedRecord: FetchableRecord, PersistableRecord {}

public extension TimestampedRecord {
    static func databaseDateEncodingStrategy(for _: String) -> DatabaseDateEncodingStrategy {
        .custom { Timestamp.string($0) }
    }

    static func databaseDateDecodingStrategy(for _: String) -> DatabaseDateDecodingStrategy {
        .custom { value in String.fromDatabaseValue(value).flatMap(Timestamp.date) }
    }
}

/// Sync columns shared by user-data tables (ADR-0003).
public protocol SyncedRecord: TimestampedRecord {
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
    var revision: Int { get set }
}

extension SyncedRecord {
    /// Stamps a new row.
    mutating func stampCreated(_ now: Date) {
        createdAt = now
        updatedAt = now
        deletedAt = nil
        revision = 1
    }

    /// Stamps an update: new `updated_at`, `revision` + 1.
    mutating func stampUpdated(_ now: Date) {
        updatedAt = now
        revision += 1
    }

    mutating func stampDeleted(_ now: Date) {
        deletedAt = now
        stampUpdated(now)
    }

    /// Soft-deletes the live rows of `ids` (missing and already deleted ones are skipped). Returns the ids it deleted,
    /// in order, for the caller's follow-ups (e.g. queuing Apple Health writes).
    @discardableResult
    static func softDelete(_ db: Database, ids: [String], now: Date) throws -> [String] {
        var changed: [String] = []
        for id in ids {
            guard var record = try fetchOne(db, key: id), record.deletedAt == nil else { continue }
            record.stampDeleted(now)
            try record.update(db)
            changed.append(id)
        }
        return changed
    }

    /// Undo for ``softDelete(_:ids:now:)``: restores the deleted rows of `ids` (missing and live ones are skipped),
    /// after `prepare` adjusted each one. Returns the ids it restored, in order.
    @discardableResult
    static func restore(
        _ db: Database, ids: [String], now: Date, prepare: (Database, inout Self) throws -> Void = { _, _ in },
    ) throws -> [String] {
        var changed: [String] = []
        for id in ids {
            guard var record = try fetchOne(db, key: id), record.deletedAt != nil else { continue }
            try prepare(db, &record)
            record.deletedAt = nil
            record.stampUpdated(now)
            try record.update(db)
            changed.append(id)
        }
        return changed
    }
}

/// A row placed in a day's meal slot by `sort_order`: diary entries and planned entries.
protocol SlottedEntry: SyncedRecord {
    var id: String { get }
    var day: LocalDay { get set }
    var mealSlotID: String { get set }
    var sortOrder: Int { get set }
}

extension SlottedEntry {
    /// The position after the last row of `day`'s slot `slotID` (deleted rows included).
    static func nextSortOrder(_ db: Database, day: LocalDay, slotID: String) throws -> Int {
        let max = try Int.fetchOne(db, sql: """
        SELECT MAX(sort_order) FROM \(databaseTableName) WHERE day = ? AND meal_slot_id = ?
        """, arguments: [day, slotID])
        return (max ?? -1) + 1
    }

    /// Moves row `id` to another slot and/or day, at the end of the target slot. Returns false when it is already
    /// there (nothing changes); throws `notFound` for a missing row.
    static func move(_ db: Database, id: String, toSlot slotID: String, day: LocalDay, now: Date) throws -> Bool {
        guard var entry = try fetchOne(db, key: id) else { throw PersistenceError.notFound(id) }
        guard entry.mealSlotID != slotID || entry.day != day else { return false }
        entry.sortOrder = try nextSortOrder(db, day: day, slotID: slotID)
        entry.mealSlotID = slotID
        entry.day = day
        entry.stampUpdated(now)
        try entry.update(db)
        return true
    }
}

extension String? {
    /// nil for nil or blank (whitespace-only) text, else the text unchanged.
    var nonBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

/// New random UUID string (lowercase, portable TEXT primary key).
public func newID() -> String {
    UUID().uuidString.lowercased()
}

// MARK: - Database value conversions for Core types

extension LocalDay: @retroactive DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        isoString.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalDay? {
        String.fromDatabaseValue(dbValue).flatMap(LocalDay.init)
    }
}

extension Sex: @retroactive DatabaseValueConvertible {}
extension ActivityLevel: @retroactive DatabaseValueConvertible {}
extension GoalMode: @retroactive DatabaseValueConvertible {}
extension HydrationGoalMode: @retroactive DatabaseValueConvertible {}

// MARK: - Errors

public enum PersistenceError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidBarcode(String)
    /// The barcode is already attached to another (non-deleted) food.
    case barcodeInUse(barcode: String, foodID: String)
    case validation(String)
}

extension PersistenceError {
    /// Validation errors thrown from several repositories. Messages are written lowercase without a period, like every
    /// `validation` message: ``errorDescription`` makes a sentence of them.
    static var amountNotPositive: PersistenceError {
        .validation(String(localized: "amount must be greater than zero", bundle: .module))
    }

    static var quickAddHasNoQuantity: PersistenceError {
        .validation(String(localized: "quick-add entries have no quantity", bundle: .module))
    }

    static var nothingToScale: PersistenceError {
        .validation(String(localized: "entry has no amount to scale", bundle: .module))
    }
}

/// Alerts show `localizedDescription`; without this they read "The operation couldn't be completed. (… error 3.)".
extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "That item no longer exists.", bundle: .module)
        case .invalidBarcode: String(localized: "That barcode isn't valid.", bundle: .module)
        case .barcodeInUse: String(localized: "That barcode is already used by another food.", bundle: .module)
        case let .validation(message): Self.sentence(message)
        }
    }

    /// The authored message (localized where it is thrown), capitalized and ending in a period ("amount must be
    /// greater than zero" reads "Amount must be greater than zero.").
    private static func sentence(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return String(localized: "That isn't valid.", bundle: .module) }
        let capitalized = first.uppercased() + trimmed.dropFirst()
        return capitalized.last.map { ".!?".contains($0) } == true ? capitalized : capitalized + "."
    }
}
