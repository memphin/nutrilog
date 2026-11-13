import Core
import Foundation
import GRDB

/// One `daily_metrics` row: the per-day cache of Apple Health (SPEC §8). Health stays the system of record,
/// so the table can be emptied and rebuilt at any time.
public struct DailyMetricsRecord: Codable, Hashable, Sendable, TimestampedRecord {
    public static let databaseTableName = "daily_metrics"

    public var day: LocalDay
    public var steps: Int?
    public var activeKcal: Double?
    public var basalKcal: Double?
    public var sleepAsleepMin: Int?
    public var sleepInBedMin: Int?
    public var sleepCoreMin: Int?
    public var sleepDeepMin: Int?
    public var sleepRemMin: Int?
    public var sleepAwakeMin: Int?
    /// When the user woke up, from the night's sleep (see `DailyHealthMetrics.wokeAt`).
    public var wokeAt: Date?
    public var weightKg: Double?
    public var bodyFatPct: Double?
    /// EMA weight trend, computed by Core (phase 3); kept as is when Health values are refreshed.
    public var weightTrendKg: Double?
    public var restingHR: Double?
    public var hrvSDNNms: Double?
    public var waterMl: Double?
    /// JSON object metric → source name, e.g. `{"steps":"Ivan's Apple Watch","weight":"Withings"}`.
    public var sourceSummary: String?
    /// When Health was last read for this day (changes on every refresh).
    public var fetchedAt: Date
    /// When a value last changed.
    public var updatedAt: Date
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case day, steps, revision
        case activeKcal = "active_kcal"
        case basalKcal = "basal_kcal"
        case sleepAsleepMin = "sleep_asleep_min"
        case sleepInBedMin = "sleep_in_bed_min"
        case sleepCoreMin = "sleep_core_min"
        case sleepDeepMin = "sleep_deep_min"
        case sleepRemMin = "sleep_rem_min"
        case sleepAwakeMin = "sleep_awake_min"
        case wokeAt = "woke_at"
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
        case weightTrendKg = "weight_trend_kg"
        case restingHR = "resting_hr"
        case hrvSDNNms = "hrv_sdnn_ms"
        case waterMl = "water_ml"
        case sourceSummary = "source_summary"
        case fetchedAt = "fetched_at"
        case updatedAt = "updated_at"
    }

    public typealias Columns = CodingKeys

    public init(_ metrics: DailyHealthMetrics, fetchedAt: Date) {
        day = metrics.day
        steps = metrics.steps
        activeKcal = metrics.activeKcal
        basalKcal = metrics.basalKcal
        sleepAsleepMin = metrics.sleepAsleepMin
        sleepInBedMin = metrics.sleepInBedMin
        sleepCoreMin = metrics.sleepCoreMin
        sleepDeepMin = metrics.sleepDeepMin
        sleepRemMin = metrics.sleepRemMin
        sleepAwakeMin = metrics.sleepAwakeMin
        wokeAt = metrics.wokeAt
        weightKg = metrics.weightKg
        bodyFatPct = metrics.bodyFatPct
        restingHR = metrics.restingHR
        hrvSDNNms = metrics.hrvSDNNms
        waterMl = metrics.waterMl
        sourceSummary = metrics.sourceSummaryJSON
        self.fetchedAt = fetchedAt
        updatedAt = fetchedAt
        revision = 1
    }

    /// The Health values of the row (without the trend and bookkeeping columns).
    public var metrics: DailyHealthMetrics {
        DailyHealthMetrics(
            day: day, steps: steps, activeKcal: activeKcal, basalKcal: basalKcal,
            sleepAsleepMin: sleepAsleepMin, sleepInBedMin: sleepInBedMin, sleepCoreMin: sleepCoreMin,
            sleepDeepMin: sleepDeepMin, sleepRemMin: sleepRemMin, sleepAwakeMin: sleepAwakeMin, wokeAt: wokeAt,
            weightKg: weightKg, bodyFatPct: bodyFatPct, restingHR: restingHR, hrvSDNNms: hrvSDNNms, waterMl: waterMl,
            sources: DailyHealthMetrics.sources(fromJSON: sourceSummary),
        )
    }
}

/// Reads and writes the `daily_metrics` cache filled from Apple Health (backlog #24).
public struct DailyMetricsRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Inserts or refreshes one row per day. Every row gets a new `fetched_at`; only rows whose values changed
    /// get a new `updated_at` and `revision + 1`, so refreshing unchanged days creates no sync traffic.
    /// `weight_trend_kg` is preserved. Returns the number of rows inserted or changed.
    @discardableResult
    public func upsert(_ metrics: [DailyHealthMetrics]) throws -> Int {
        let now = clock.now()
        return try database.writer.write { db in
            var changed = 0
            for var item in metrics {
                guard var existing = try DailyMetricsRecord.fetchOne(db, key: item.day) else {
                    try DailyMetricsRecord(item, fetchedAt: now).insert(db)
                    changed += 1
                    continue
                }
                // Stored timestamps keep milliseconds and don't parse back bit for bit: a wake-up time that differs
                // from the stored one only by that rounding is the same, or every refresh would look like a change.
                if let woke = item.wokeAt, let stored = existing.wokeAt, abs(woke.timeIntervalSince(stored)) < 0.002 {
                    item.wokeAt = stored
                }
                if existing.metrics == item {
                    existing.fetchedAt = now
                    try existing.update(db, columns: [DailyMetricsRecord.Columns.fetchedAt])
                } else {
                    var updated = DailyMetricsRecord(item, fetchedAt: now)
                    updated.weightTrendKg = existing.weightTrendKg
                    updated.revision = existing.revision + 1
                    try updated.update(db)
                    changed += 1
                }
            }
            return changed
        }
    }

    /// Stores the weight trend (`WeightTrend.compute`, backlog #33) on the rows of the given days. Only days that
    /// already have a row are written (the table is a cache of Health; the trend itself can always be recomputed
    /// from the weights), and only rows whose value changed get a new `updated_at` / `revision`.
    /// Returns the number of rows changed.
    @discardableResult
    public func setWeightTrends(_ trends: [LocalDay: Double]) throws -> Int {
        guard let first = trends.keys.min(), let last = trends.keys.max() else { return 0 }
        let now = clock.now()
        return try database.writer.write { db in
            var changed = 0
            for var row in try Self.request(first ... last).fetchAll(db) {
                guard let trend = trends[row.day] else { continue }
                if let stored = row.weightTrendKg, abs(stored - trend) < 0.0005 {
                    continue
                }
                row.weightTrendKg = trend
                row.updatedAt = now
                row.revision += 1
                try row.update(db, columns: [
                    DailyMetricsRecord.Columns.weightTrendKg, DailyMetricsRecord.Columns.updatedAt, DailyMetricsRecord.Columns.revision,
                ])
                changed += 1
            }
            return changed
        }
    }

    /// The latest stored weight trend on or before `day` (e.g. the body weight for the hydration goal), or nil when
    /// there is none yet.
    public func weightTrendKg(onOrBefore day: LocalDay) throws -> Double? {
        try database.reader.read { db in try Self.weightTrendKg(db, onOrBefore: day) }
    }

    /// For each day in `days`, the latest stored weight trend on or before it. Days before the first trend are absent.
    public func weightTrends(in days: ClosedRange<LocalDay>) throws -> [LocalDay: Double] {
        try database.reader.read { db in
            var trends: [LocalDay: Double] = [:]
            for row in try Row.fetchAll(db, sql: """
            SELECT day, weight_trend_kg FROM daily_metrics
            WHERE weight_trend_kg IS NOT NULL AND day >= ? AND day <= ?
            """, arguments: [days.lowerBound, days.upperBound]) {
                trends[row["day"]] = row["weight_trend_kg"]
            }
            var result: [LocalDay: Double] = [:]
            var latest = try Self.weightTrendKg(db, onOrBefore: days.lowerBound)
            var day = days.lowerBound
            while day <= days.upperBound {
                latest = trends[day] ?? latest
                if let latest {
                    result[day] = latest
                }
                day = day.next
            }
            return result
        }
    }

    public func metrics(on day: LocalDay) throws -> DailyMetricsRecord? {
        try database.reader.read { db in try DailyMetricsRecord.fetchOne(db, key: day) }
    }

    /// Rows for the days in `days` that have been fetched, oldest first.
    public func metrics(in days: ClosedRange<LocalDay>) throws -> [DailyMetricsRecord] {
        try database.reader.read { db in try Self.request(days).fetchAll(db) }
    }

    public func observeMetrics(on day: LocalDay) -> AsyncValueObservation<DailyMetricsRecord?> {
        database.observe { db in try DailyMetricsRecord.fetchOne(db, key: day) }
    }

    public func observeMetrics(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[DailyMetricsRecord]> {
        database.observe { db in try Self.request(days).fetchAll(db) }
    }

    /// Empties the cache (it can always be rebuilt from Health).
    public func deleteAll() throws {
        try database.writer.write { db in _ = try DailyMetricsRecord.deleteAll(db) }
    }

    private static func weightTrendKg(_ db: Database, onOrBefore day: LocalDay) throws -> Double? {
        try Double.fetchOne(db, sql: """
        SELECT weight_trend_kg FROM daily_metrics WHERE weight_trend_kg IS NOT NULL AND day <= ? ORDER BY day DESC LIMIT 1
        """, arguments: [day])
    }

    private static func request(_ days: ClosedRange<LocalDay>) -> QueryInterfaceRequest<DailyMetricsRecord> {
        DailyMetricsRecord
            .filter(DailyMetricsRecord.Columns.day >= days.lowerBound && DailyMetricsRecord.Columns.day <= days.upperBound)
            .order(DailyMetricsRecord.Columns.day)
    }
}
