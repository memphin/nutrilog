import Foundation

// Plain value copies of Apple Health data (SPEC §3.4). HealthKitClient converts HealthKit objects into these,
// so Core stays free of HealthKit and every rule here is testable on macOS with fixed time zones.

// MARK: - Sources

/// Where a Health value came from: the fields of `HKSource` / `HKSourceRevision` that the rules need.
public struct HealthSource: Hashable, Sendable, Codable {
    /// User-visible name, e.g. "Ivan's Apple Watch", "Withings".
    public var name: String
    /// `HKSource.bundleIdentifier`. Apple devices write as "com.apple.health.<device UUID>", one per device.
    public var bundleIdentifier: String
    /// `HKSourceRevision.productType`, e.g. "Watch7,1" or "iPhone17,1". Nil when unknown (statistics queries).
    public var productType: String?

    public init(name: String, bundleIdentifier: String, productType: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.productType = productType
    }

    /// Only Apple's own device sources ("com.apple.health.<UUID>") count as Apple Watch or iPhone; a third-party
    /// app is `.app` even when it runs on a watch.
    public var kind: HealthSourceKind {
        guard bundleIdentifier.hasPrefix("com.apple.health.") else { return .app }
        return productType?.hasPrefix("Watch") == true ? .appleWatch : .iPhone
    }
}

/// Source classes in priority order (SPEC D5: Apple Watch first for sleep, heart rate and HRV).
public enum HealthSourceKind: Int, Comparable, Sendable, Codable, CaseIterable {
    /// Recorded by Apple's own software on an Apple Watch.
    case appleWatch = 0
    /// Another app or device writing to Health (Withings, sleep apps — also their watch apps — and manual
    /// entries in the Health app).
    case app = 1
    /// Apple's own iPhone estimates (in-bed time from the sleep schedule, phone steps).
    case iPhone = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Samples and statistics

/// A discrete quantity sample (weight, body fat, heart rate, …) in the metric's canonical unit.
public struct HealthQuantitySample: Hashable, Sendable, Codable {
    public var start: Date
    public var end: Date
    /// Value in `SampledMetric.unitSymbol`.
    public var value: Double
    public var source: HealthSource
    /// `HKMetadataKeyExternalUUID`: for samples Vitalion wrote, the id of the row they mirror (`weight_entry.id`,
    /// `water_entry.id`). Nil when the sample has none (most other apps) or it was not read.
    public var externalID: String?

    public init(start: Date, end: Date? = nil, value: Double, source: HealthSource, externalID: String? = nil) {
        self.start = start
        self.end = end ?? start
        self.value = value
        self.source = source
        self.externalID = externalID
    }
}

/// One source's share of a cumulative statistic (before Health's de-duplication).
public struct SourceContribution: Hashable, Sendable, Codable {
    public var source: HealthSource
    public var sum: Double

    public init(source: HealthSource, sum: Double) {
        self.source = source
        self.sum = sum
    }
}

/// One interval of a cumulative statistics query (steps, energy, water).
public struct CumulativeStatistic: Hashable, Sendable, Codable {
    public var start: Date
    public var end: Date
    /// Total for the interval, de-duplicated across sources by Health (iPhone + Watch steps count once).
    public var sum: Double
    /// Per-source totals, used only to name the main source in the source summary.
    public var sources: [SourceContribution]

    public init(start: Date, end: Date, sum: Double, sources: [SourceContribution] = []) {
        self.start = start
        self.end = end
        self.sum = sum
        self.sources = sources
    }

    /// The source that contributed most (ties broken by name, so the result is stable).
    public var mainSource: HealthSource? {
        sources.max { lhs, rhs in
            lhs.sum != rhs.sum ? lhs.sum < rhs.sum : lhs.source.name > rhs.source.name
        }?.source
    }
}

public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case inBed
    case asleepUnspecified
    case asleepCore
    case asleepDeep
    case asleepREM
    case awake

    public var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
        case .inBed, .awake: false
        }
    }
}

/// One `sleepAnalysis` category sample.
public struct SleepSample: Hashable, Sendable, Codable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var source: HealthSource

    public init(start: Date, end: Date, stage: SleepStage, source: HealthSource) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
    }
}

// MARK: - Metrics

/// Health types summed per day with a statistics collection query (de-duplicated by Health).
public enum CumulativeMetric: String, Sendable, Codable, CaseIterable {
    case steps, activeEnergy, basalEnergy, dietaryWater

    /// Canonical unit of `CumulativeStatistic.sum`.
    public var unitSymbol: String {
        switch self {
        case .steps: "count"
        case .activeEnergy, .basalEnergy: "kcal"
        case .dietaryWater: "ml"
        }
    }
}

/// Health types read as individual samples and reduced per day by `DailyMetricsAggregator`.
public enum SampledMetric: String, Sendable, Codable, CaseIterable {
    case bodyMass, bodyFatPercentage, restingHeartRate, heartRateVariabilitySDNN

    /// Canonical unit of `HealthQuantitySample.value`. Body fat is a percentage (18.5), not a fraction.
    public var unitSymbol: String {
        switch self {
        case .bodyMass: "kg"
        case .bodyFatPercentage: "%"
        case .restingHeartRate: "count/min"
        case .heartRateVariabilitySDNN: "ms"
        }
    }
}

/// The values of one `daily_metrics` row; raw values are the keys of the source-summary JSON.
public enum HealthMetric: String, Sendable, Codable, CaseIterable {
    case steps
    case activeEnergy = "active_kcal"
    case basalEnergy = "basal_kcal"
    case sleep
    case weight
    case bodyFat = "body_fat"
    case restingHeartRate = "resting_hr"
    case hrv
    case water
}

// MARK: - Fetch batch and plan

/// Everything read from Health for a range of days — the input of `DailyMetricsAggregator`.
public struct HealthDataBatch: Hashable, Sendable {
    public var days: ClosedRange<LocalDay>
    public var statistics: [CumulativeMetric: [CumulativeStatistic]]
    public var samples: [SampledMetric: [HealthQuantitySample]]
    public var sleep: [SleepSample]
    /// Individual `dietaryWater` samples with their external ids, used only to tell which of Vitalion's own water
    /// still has a local `water_entry` row (the totals come from `statistics`). The live source reads only the app's
    /// own samples here. Nil when not read: all own water is then treated as local.
    public var waterSamples: [HealthQuantitySample]?
    /// The workouts that started on `days` (the Training tab); not part of `daily_metrics`.
    public var workouts: [HealthWorkout]

    public init(
        days: ClosedRange<LocalDay>,
        statistics: [CumulativeMetric: [CumulativeStatistic]] = [:],
        samples: [SampledMetric: [HealthQuantitySample]] = [:],
        sleep: [SleepSample] = [],
        waterSamples: [HealthQuantitySample]? = nil,
        workouts: [HealthWorkout] = [],
    ) {
        self.days = days
        self.statistics = statistics
        self.samples = samples
        self.sleep = sleep
        self.waterSamples = waterSamples
        self.workouts = workouts
    }
}

/// The time intervals to query for a range of local days, in `calendar`'s time zone (DST-aware).
public struct HealthFetchPlan: Hashable, Sendable {
    public let days: ClosedRange<LocalDay>
    public let calendar: Calendar
    /// [00:00 of the first day, 00:00 of the day after the last) — statistics and per-day samples.
    /// Also the anchor of the daily statistics buckets.
    public let dayInterval: DateInterval
    /// (18:00 before the first night, 18:00 of the last day] — sleep samples by end date.
    public let sleepInterval: DateInterval

    public init(days: ClosedRange<LocalDay>, calendar: Calendar = .current) {
        self.days = days
        self.calendar = calendar
        dayInterval = DateInterval(
            start: days.lowerBound.startDate(calendar: calendar),
            end: days.upperBound.next.startDate(calendar: calendar),
        )
        sleepInterval = DateInterval(
            start: SleepAggregator.nightWindow(for: days.lowerBound, calendar: calendar).start,
            end: SleepAggregator.nightWindow(for: days.upperBound, calendar: calendar).end,
        )
    }

    /// The day containing `date`, or nil when it lies outside the plan.
    public func day(containing date: Date) -> LocalDay? {
        let day = LocalDay(date, calendar: calendar)
        return days.contains(day) ? day : nil
    }

    /// Every day of the plan, oldest first.
    public var allDays: [LocalDay] {
        days.days
    }
}

public extension LocalDay {
    /// [00:00 this day, 00:00 next day) in `calendar` — 23 or 25 hours long on DST change days.
    func dateInterval(calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: startDate(calendar: calendar), end: next.startDate(calendar: calendar))
    }

    /// This day at `hour`:00 local time. An hour skipped by a DST change resolves to the next valid time.
    func date(atHour hour: Int, calendar: Calendar = .current) -> Date {
        LocalDay.gregorian(calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
