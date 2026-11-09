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

// MARK: - Errors

public enum PersistenceError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidBarcode(String)
    /// The barcode is already attached to another (non-deleted) food.
    case barcodeInUse(barcode: String, foodID: String)
    case validation(String)
}
