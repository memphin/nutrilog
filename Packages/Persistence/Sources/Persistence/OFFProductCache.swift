import Foundation
import GRDB

/// One row of the Open Food Facts product cache: what OFF answered for a barcode, and when.
public struct OFFProductCacheEntry: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// OFF has the product; `json` is the encoded product as the caller stored it.
        case product(json: Data, lastModifiedT: Int?)
        /// OFF answered that it has no product for this code (a negative cache entry).
        case notFound
    }

    /// Normalized key (EAN-13 / EAN-8) the product was looked up under.
    public var barcode: String
    public var content: Content
    /// When OFF answered.
    public var fetchedAt: Date

    public init(barcode: String, content: Content, fetchedAt: Date) {
        self.barcode = barcode
        self.content = content
        self.fetchedAt = fetchedAt
    }

    /// Seconds since OFF answered (negative when `fetchedAt` is in the future, e.g. after a clock change).
    public func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(fetchedAt)
    }
}

/// Reads and writes the `off_product_cache` table (backlog #19, SPEC §9).
///
/// A plain store: it keeps the product JSON it is given and leaves freshness rules to the barcode pipeline
/// (`FoodLookup.BarcodeLookup`), so Persistence does not depend on FoodSources. The table is a re-fetchable cache:
/// it is not exported (``DataPortability``), and old rows are removed with ``evictEntries(olderThan:)``.
public struct OFFProductCache: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    public func entry(barcode: String) throws -> OFFProductCacheEntry? {
        try database.reader.read { db in try Row.fetchOne(db, key: barcode) }?.entry
    }

    /// Stores (or replaces) the product found for `barcode`, stamped now.
    public func storeProduct(barcode: String, json: Data, lastModifiedT: Int?) throws {
        guard let text = String(data: json, encoding: .utf8) else {
            throw PersistenceError.validation("Cached product JSON is not UTF-8")
        }
        let row = Row(barcode: barcode, status: .found, json: text, lastModifiedT: lastModifiedT, fetchedAt: clock.now())
        try database.writer.write { db in try row.save(db) }
    }

    /// Remembers that OFF has no product for `barcode` (replacing any earlier entry), stamped now.
    public func storeNotFound(barcode: String) throws {
        let row = Row(barcode: barcode, status: .notFound, json: nil, lastModifiedT: nil, fetchedAt: clock.now())
        try database.writer.write { db in try row.save(db) }
    }

    /// Deletes every entry fetched more than `maxAge` seconds ago; returns how many were deleted.
    @discardableResult
    public func evictEntries(olderThan maxAge: TimeInterval) throws -> Int {
        let cutoff = Timestamp.string(clock.now().addingTimeInterval(-maxAge))
        return try database.writer.write { db in
            try Row.filter(Row.Columns.fetchedAt < cutoff).deleteAll(db)
        }
    }

    public func count() throws -> Int {
        try database.reader.read { db in try Row.fetchCount(db) }
    }

    typealias Row = OFFProductCacheRow
}

// MARK: - Record

/// A row of `off_product_cache`.
struct OFFProductCacheRow: Codable, Sendable, TimestampedRecord {
    static let databaseTableName = "off_product_cache"

    enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case found
        case notFound = "not_found"
    }

    var barcode: String
    var status: Status
    var json: String?
    var lastModifiedT: Int?
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case barcode, status, json
        case lastModifiedT = "last_modified_t"
        case fetchedAt = "fetched_at"
    }

    typealias Columns = CodingKeys

    var entry: OFFProductCacheEntry? {
        switch status {
        case .found:
            guard let json else { return nil }
            return OFFProductCacheEntry(
                barcode: barcode, content: .product(json: Data(json.utf8), lastModifiedT: lastModifiedT),
                fetchedAt: fetchedAt,
            )
        case .notFound:
            return OFFProductCacheEntry(barcode: barcode, content: .notFound, fetchedAt: fetchedAt)
        }
    }
}
