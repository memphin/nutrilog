import Foundation

/// One day of Health data — the values of a `daily_metrics` row (SPEC §8), computed by `DailyMetricsAggregator`.
public struct DailyHealthMetrics: Hashable, Sendable, Codable {
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
    /// First weigh-in of the day from *other* sources: weights Nutrilog wrote itself (manual entries) are excluded,
    /// they live in `weight_entry` and `WeightReconciler` merges both.
    public var weightKg: Double?
    /// Body fat in percent (18.5), from the same measurement as the weight when there is one.
    public var bodyFatPct: Double?
    public var restingHR: Double?
    /// Average SDNN of the samples taken 00:00–09:00.
    public var hrvSDNNms: Double?
    /// Water logged in Health by *other* apps. Water Nutrilog wrote itself is excluded (see
    /// `DailyMetricsAggregator.aggregate(_:calendar:excludingOwnSamplesFrom:)`): it lives in `water_entry`, and the day's
    /// total is `water_entry` + this value, so nothing is counted twice whether or not writing to Health is on.
    public var waterMl: Double?
    /// Name of the source that provided each metric, e.g. [.steps: "Ivan's Apple Watch", .weight: "Withings"].
    public var sources: [HealthMetric: String]

    public init(
        day: LocalDay,
        steps: Int? = nil,
        activeKcal: Double? = nil,
        basalKcal: Double? = nil,
        sleepAsleepMin: Int? = nil,
        sleepInBedMin: Int? = nil,
        sleepCoreMin: Int? = nil,
        sleepDeepMin: Int? = nil,
        sleepRemMin: Int? = nil,
        sleepAwakeMin: Int? = nil,
        weightKg: Double? = nil,
        bodyFatPct: Double? = nil,
        restingHR: Double? = nil,
        hrvSDNNms: Double? = nil,
        waterMl: Double? = nil,
        sources: [HealthMetric: String] = [:],
    ) {
        self.day = day
        self.steps = steps
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.sleepAsleepMin = sleepAsleepMin
        self.sleepInBedMin = sleepInBedMin
        self.sleepCoreMin = sleepCoreMin
        self.sleepDeepMin = sleepDeepMin
        self.sleepRemMin = sleepRemMin
        self.sleepAwakeMin = sleepAwakeMin
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.restingHR = restingHR
        self.hrvSDNNms = hrvSDNNms
        self.waterMl = waterMl
        self.sources = sources
    }

    /// Whether the day has a value for `metric` (sleep: time in bed or asleep).
    public func hasValue(_ metric: HealthMetric) -> Bool {
        switch metric {
        case .steps: steps != nil
        case .activeEnergy: activeKcal != nil
        case .basalEnergy: basalKcal != nil
        case .sleep: sleepInBedMin != nil || sleepAsleepMin != nil
        case .weight: weightKg != nil
        case .bodyFat: bodyFatPct != nil
        case .restingHeartRate: restingHR != nil
        case .hrv: hrvSDNNms != nil
        case .water: waterMl != nil
        }
    }

    /// True when Health had nothing for this day (or read access is denied — the two look the same).
    public var isEmpty: Bool {
        !HealthMetric.allCases.contains { hasValue($0) }
    }

    /// Fills the sleep columns from a night summary. Stage minutes stay nil when the source has no stages.
    public mutating func apply(sleep summary: SleepSummary) {
        sleepInBedMin = Self.minutes(summary.inBed)
        sleepAsleepMin = summary.asleep.map(Self.minutes)
        if summary.hasStages {
            sleepCoreMin = Self.minutes(summary.core)
            sleepDeepMin = Self.minutes(summary.deep)
            sleepRemMin = Self.minutes(summary.rem)
            sleepAwakeMin = Self.minutes(summary.awake)
        }
        sources[.sleep] = summary.source.name
    }

    static func minutes(_ interval: TimeInterval) -> Int {
        Int((interval / 60).rounded())
    }
}

// MARK: - Source summary JSON

public extension DailyHealthMetrics {
    /// `{"steps":"Ivan's Apple Watch","weight":"Withings"}` with sorted keys; nil when no metric has a source.
    var sourceSummaryJSON: String? {
        guard !sources.isEmpty else { return nil }
        let plain = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(plain) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a source-summary JSON. Unknown keys (from newer app versions) and malformed JSON are ignored.
    static func sources(fromJSON json: String?) -> [HealthMetric: String] {
        guard let json, let plain = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return [:] }
        var result: [HealthMetric: String] = [:]
        for (key, value) in plain {
            if let metric = HealthMetric(rawValue: key) {
                result[metric] = value
            }
        }
        return result
    }
}

// MARK: - Aggregation

/// Reduces a `HealthDataBatch` to one `DailyHealthMetrics` per day (backlog #24, SPEC §3.4).
///
/// Day boundaries are local midnights in the given calendar, so DST days are 23 or 25 hours long.
/// - Steps, active/basal energy, water: the de-duplicated statistic of the day; the main contributor is the source.
/// - Weight: the earliest sample of the day (the morning weigh-in). Body fat: the sample from the same
///   measurement (same source, within five minutes) when present, else the earliest of the day.
/// - Resting heart rate: the latest sample of the day from the highest-priority source (Apple Watch first).
/// - HRV: the average of the samples taken 00:00–09:00, Apple Watch samples only when there are any.
/// - Sleep: `SleepAggregator` for the night ending on the day.
/// - Water: as the cumulative metrics, minus the water written by the sources in `excludingOwnSamplesFrom` (Nutrilog
///   itself), so water the app logged and wrote to Health is not counted twice (SPEC §3.4 write loops, FR-46).
/// - Weight and body fat written by those sources (manual weights, FR-42) are ignored the same way: they live in
///   `weight_entry`, and `WeightReconciler` merges them with the values read here.
public enum DailyMetricsAggregator {
    /// HRV counts samples from midnight until this hour (overnight average).
    public static let hrvWindowEndHour = 9
    /// Body fat taken this close to the weight, by the same source, is treated as the same measurement.
    public static let sameMeasurementTolerance: TimeInterval = 5 * 60

    /// - Parameter excludingOwnSamplesFrom: bundle identifiers whose `dietaryWater` contribution is subtracted and
    ///   whose weight and body fat samples are ignored — Nutrilog's own, so what the app logged (and wrote to Health)
    ///   is not read back as data from other apps.
    public static func aggregate(
        _ batch: HealthDataBatch,
        calendar: Calendar = .current,
        excludingOwnSamplesFrom excludedSources: Set<String> = [],
    ) -> [DailyHealthMetrics] {
        let plan = HealthFetchPlan(days: batch.days, calendar: calendar)
        var days: [LocalDay: DailyHealthMetrics] = [:]
        for day in plan.allDays {
            days[day] = DailyHealthMetrics(day: day)
        }

        for (metric, statistics) in batch.statistics {
            apply(metric, statistics: statistics, plan: plan, excluding: metric == .dietaryWater ? excludedSources : [], to: &days)
        }

        let ownBody: Set<SampledMetric> = [.bodyMass, .bodyFatPercentage]
        let samplesByDay = batch.samples.reduce(into: [SampledMetric: [LocalDay?: [HealthQuantitySample]]]()) { result, entry in
            let samples = ownBody.contains(entry.key)
                ? entry.value.filter { !excludedSources.contains($0.source.bundleIdentifier) }
                : entry.value
            result[entry.key] = Dictionary(grouping: samples) { plan.day(containing: $0.start) }
        }
        for day in plan.allDays {
            let samples = { (metric: SampledMetric) in samplesByDay[metric]?[day] ?? [] }
            days[day]?.applyBody(weights: samples(.bodyMass), bodyFat: samples(.bodyFatPercentage))
            days[day]?.applyRestingHeartRate(samples(.restingHeartRate))
            let hrvWindow = DateInterval(
                start: day.startDate(calendar: calendar),
                end: day.date(atHour: hrvWindowEndHour, calendar: calendar),
            )
            days[day]?.applyHRV(samples(.heartRateVariabilitySDNN).filter { $0.start >= hrvWindow.start && $0.start < hrvWindow.end })
        }

        for (night, summary) in SleepAggregator.aggregate(samples: batch.sleep, nights: batch.days, calendar: calendar) {
            days[night]?.apply(sleep: summary)
        }

        return plan.allDays.compactMap { days[$0] }
    }

    private static func apply(
        _ metric: CumulativeMetric,
        statistics: [CumulativeStatistic],
        plan: HealthFetchPlan,
        excluding excludedSources: Set<String>,
        to days: inout [LocalDay: DailyHealthMetrics],
    ) {
        // A statistic covers one local day; its midpoint is safely inside that day even if the bucket
        // edges are off by a little.
        let byDay = Dictionary(grouping: statistics) { stat in
            plan.day(containing: stat.start.addingTimeInterval(stat.end.timeIntervalSince(stat.start) / 2))
        }
        for (day, stats) in byDay {
            guard let day else { continue }
            var total = stats.reduce(0) { $0 + $1.sum }
            var sources = stats.flatMap(\.sources)
            if !excludedSources.isEmpty {
                let excluded = sources.filter { excludedSources.contains($0.source.bundleIdentifier) }
                guard excluded.isEmpty || sources.count > excluded.count else { continue } // only our own samples
                // Per-source sums are taken before Health's de-duplication, so clamp at zero.
                total = max(0, total - excluded.reduce(0) { $0 + $1.sum })
                sources.removeAll { excludedSources.contains($0.source.bundleIdentifier) }
            }
            let merged = CumulativeStatistic(start: stats[0].start, end: stats[0].end, sum: total, sources: sources)
            let source = merged.mainSource?.name
            switch metric {
            case .steps:
                days[day]?.steps = Int(total.rounded())
                days[day]?.sources[.steps] = source
            case .activeEnergy:
                days[day]?.activeKcal = total
                days[day]?.sources[.activeEnergy] = source
            case .basalEnergy:
                days[day]?.basalKcal = total
                days[day]?.sources[.basalEnergy] = source
            case .dietaryWater:
                days[day]?.waterMl = total
                days[day]?.sources[.water] = source
            }
        }
    }
}

private extension DailyHealthMetrics {
    mutating func applyBody(weights: [HealthQuantitySample], bodyFat: [HealthQuantitySample]) {
        let weight = weights.min(by: Self.earlier)
        if let weight {
            weightKg = weight.value
            sources[.weight] = weight.source.name
        }
        let sameMeasurement = weight.flatMap { weight in
            bodyFat.filter {
                $0.source.bundleIdentifier == weight.source.bundleIdentifier
                    && abs($0.start.timeIntervalSince(weight.start)) <= DailyMetricsAggregator.sameMeasurementTolerance
            }.min(by: Self.earlier)
        }
        if let fat = sameMeasurement ?? bodyFat.min(by: Self.earlier) {
            bodyFatPct = fat.value
            sources[.bodyFat] = fat.source.name
        }
    }

    mutating func applyRestingHeartRate(_ samples: [HealthQuantitySample]) {
        guard let latest = Self.preferredSourceKind(samples).max(by: Self.earlier) else { return }
        restingHR = latest.value
        sources[.restingHeartRate] = latest.source.name
    }

    mutating func applyHRV(_ samples: [HealthQuantitySample]) {
        let preferred = Self.preferredSourceKind(samples)
        guard !preferred.isEmpty else { return }
        hrvSDNNms = preferred.reduce(0) { $0 + $1.value } / Double(preferred.count)
        // Name the source that provided most of the samples.
        let counts = Dictionary(grouping: preferred, by: \.source.name).mapValues(\.count)
        sources[.hrv] = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// The samples of the best source kind present (Apple Watch > other apps > iPhone).
    static func preferredSourceKind(_ samples: [HealthQuantitySample]) -> [HealthQuantitySample] {
        guard let best = samples.map(\.source.kind).min() else { return [] }
        return samples.filter { $0.source.kind == best }
    }

    /// Orders by start, then by source name so equal timestamps give a stable result.
    static func earlier(_ lhs: HealthQuantitySample, _ rhs: HealthQuantitySample) -> Bool {
        lhs.start != rhs.start ? lhs.start < rhs.start : lhs.source.name < rhs.source.name
    }
}
