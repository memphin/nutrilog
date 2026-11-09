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
            sleepDeepMin: sleepDeepMin, sleepRemMin: sleepRemMin, sleepAwakeMin: sleepAwakeMin,
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
            for item in metrics {
                guard var existing = try DailyMetricsRecord.fetchOne(db, key: item.day) else {
                    try DailyMetricsRecord(item, fetchedAt: now).insert(db)
                    changed += 1
                    continue
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

    public func metrics(on day: LocalDay) throws -> DailyMetricsRecord? {
        try database.reader.read { db in try DailyMetricsRecord.fetchOne(db, key: day) }
    }

    /// Rows for the days in `days` that have been fetched, oldest first.
    public func metrics(in days: ClosedRange<LocalDay>) throws -> [DailyMetricsRecord] {
        try database.reader.read { db in try Self.request(days).fetchAll(db) }
    }

    public func observeMetrics(on day: LocalDay) -> AsyncValueObservation<DailyMetricsRecord?> {
        ValueObservation.tracking { db in try DailyMetricsRecord.fetchOne(db, key: day) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    public func observeMetrics(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[DailyMetricsRecord]> {
        ValueObservation.tracking { db in try Self.request(days).fetchAll(db) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    /// Metrics with at least one value in `days`. Health read permission is opaque, so a metric missing here is
    /// either not recorded or not shared — the UI says "No data found — check Health permissions".
    public func metricsWithData(in days: ClosedRange<LocalDay>) throws -> Set<HealthMetric> {
        let rows = try metrics(in: days).map(\.metrics)
        return Set(HealthMetric.allCases.filter { metric in rows.contains { $0.hasValue(metric) } })
    }

    /// The most recent `fetched_at` of any row, or nil when Health was never read.
    public func lastFetchedAt() throws -> Date? {
        try database.reader.read { db in
            try DailyMetricsRecord.select(max(DailyMetricsRecord.Columns.fetchedAt), as: String.self).fetchOne(db)
        }
        .flatMap(Timestamp.date)
    }

    /// Empties the cache (it can always be rebuilt from Health).
    public func deleteAll() throws {
        try database.writer.write { db in _ = try DailyMetricsRecord.deleteAll(db) }
    }

    private static func request(_ days: ClosedRange<LocalDay>) -> QueryInterfaceRequest<DailyMetricsRecord> {
        DailyMetricsRecord
            .filter(DailyMetricsRecord.Columns.day >= days.lowerBound && DailyMetricsRecord.Columns.day <= days.upperBound)
            .order(DailyMetricsRecord.Columns.day)
    }
}
