import Core
import Foundation
import GRDB

/// The local barcode scan log (`barcode_scan_log`, backlog #30): how each scan resolved, for the resolution rate in
/// Settings → Barcode resolution (``BarcodeResolutionStats``, SPEC §1.3).
///
/// Private diagnostics: stays on this device, is never exported (``DataPortability``) and is never sent anywhere.
/// Rows older than ``retention`` are dropped whenever a new one is recorded, so the table stays small.
public struct ScanLogRepository: Sendable {
    /// How long rows are kept: well beyond the 14-day window the stats use.
    public static let retention: TimeInterval = 90 * 86400

    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Records one outcome for `barcode`, stamped now. `dataQuality` is the raw `DataQuality` of an OFF answer.
    public func record(barcode: String, outcome: ScanOutcome, dataQuality: DataQuality? = nil) throws {
        let now = clock.now()
        let row = Row(id: nil, scannedAt: now, barcode: barcode, outcome: outcome.rawValue, dataQuality: dataQuality?.rawValue)
        let cutoff = Timestamp.string(now.addingTimeInterval(-Self.retention))
        try database.writer.write { db in
            try row.insert(db)
            try Row.filter(Row.Columns.scannedAt < cutoff).deleteAll(db)
        }
    }

    /// Every event recorded at or after `date`, oldest first.
    public func events(since date: Date) throws -> [ScanEvent] {
        let start = Timestamp.string(date)
        let rows = try database.reader.read { db in
            try Row.filter(Row.Columns.scannedAt >= start).order(Row.Columns.scannedAt, Row.Columns.id).fetchAll(db)
        }
        return rows.compactMap(\.event)
    }

    /// The resolution stats for the last `days` days.
    public func stats(days: Int = BarcodeResolutionStats.defaultDays) throws -> BarcodeResolutionStats {
        let now = clock.now()
        let events = try events(since: now.addingTimeInterval(-Double(days) * 86400))
        return BarcodeResolutionStats(events: events, now: now, days: days)
    }

    /// Deletes the whole log.
    public func clear() throws {
        _ = try database.writer.write { db in try Row.deleteAll(db) }
    }

    public func count() throws -> Int {
        try database.reader.read { db in try Row.fetchCount(db) }
    }

    typealias Row = ScanLogRow
}

/// A row of `barcode_scan_log`.
struct ScanLogRow: Codable, Sendable, TimestampedRecord {
    static let databaseTableName = "barcode_scan_log"

    var id: Int64?
    var scannedAt: Date
    var barcode: String
    var outcome: String
    var dataQuality: String?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, barcode, outcome
        case scannedAt = "scanned_at"
        case dataQuality = "data_quality"
    }

    typealias Columns = CodingKeys

    /// Nil for an outcome this version doesn't know.
    var event: ScanEvent? {
        ScanOutcome(rawValue: outcome).map { ScanEvent(date: scannedAt, barcode: barcode, outcome: $0, dataQuality: dataQuality) }
    }
}
