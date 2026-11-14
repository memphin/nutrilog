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
    /// When the user woke up, from the night's sleep (`SleepSummary.wokeAt`); stored as `daily_metrics.woke_at`.
    public var wokeAt: Date?
    /// First weigh-in of the day from *other* sources: weights Vitalion wrote itself (manual entries) are excluded
    /// while their `weight_entry` row exists, and `WeightReconciler` merges both.
    public var weightKg: Double?
    /// Body fat in percent (18.5), from the same measurement as the weight when there is one.
    public var bodyFatPct: Double?
    public var restingHR: Double?
    /// Average SDNN of the samples taken 00:00–09:00.
    public var hrvSDNNms: Double?
    /// Water logged in Health by *other* apps. Water Vitalion wrote itself is excluded (see
    /// `DailyMetricsAggregator.aggregate(_:calendar:excludingOwnSamplesFrom:localSampleIDs:)`): it lives in
    /// `water_entry`, and the day's total is `water_entry` + this value, so nothing is counted twice whether or not
    /// writing to Health is on. Own water whose row is gone (reinstall) is included here.
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
        wokeAt: Date? = nil,
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
        self.wokeAt = wokeAt
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
        wokeAt = summary.wokeAt
        sources[.sleep] = summary.source.name
    }

    static func minutes(_ interval: TimeInterval) -> Int {
        DisplayRounding.whole(interval / 60)
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
/// - HRV: Apple Watch samples taken 00:00–09:00 (it measures several times a night, and during the day too) when
///   there are any; otherwise other apps' samples from 18:00 the evening before until 12:00. Apps such as WHOOP or
///   Oura write one reading per night, timed when the sleep started (often before midnight) or when it was processed
///   (often after 09:00), and the watch's window would miss it. The window's samples are averaged.
/// - Sleep: `SleepAggregator` for the night ending on the day.
/// - Water: as the cumulative metrics, minus the water written by the sources in `excludingOwnSamplesFrom` (Vitalion
///   itself), so water the app logged and wrote to Health is not counted twice (SPEC §3.4 write loops, FR-46).
/// - Weight and body fat written by those sources (manual weights, FR-42) are ignored the same way: they live in
///   `weight_entry`, and `WeightReconciler` merges them with the values read here.
/// - With `localSampleIDs`, only own samples whose row still exists locally are left out: after a reinstall (or a new
///   phone without the backup) the app's earlier samples in Health have no local row and are read like other data.
public enum DailyMetricsAggregator {
    /// HRV counts Apple Watch samples from midnight until this hour (overnight average).
    public static let hrvWindowEndHour = 9
    /// Other apps' HRV counts from this hour the evening before…
    public static let hrvEveningStartHour = 18
    /// …until this hour of the day.
    public static let hrvAppWindowEndHour = 12

    /// The samples of `source` that count for the HRV of `day`: [00:00, 09:00) for Apple Watch, [18:00 the evening
    /// before, 12:00) for every other source. The other sources' windows of consecutive days do not overlap, so a
    /// reading counts for one day only.
    public static func hrvWindow(for day: LocalDay, source: HealthSourceKind, calendar: Calendar = .current) -> DateInterval {
        if source == .appleWatch {
            return DateInterval(start: day.startDate(calendar: calendar), end: day.date(atHour: hrvWindowEndHour, calendar: calendar))
        }
        return DateInterval(
            start: day.adding(days: -1).date(atHour: hrvEveningStartHour, calendar: calendar),
            end: day.date(atHour: hrvAppWindowEndHour, calendar: calendar),
        )
    }
    /// Body fat taken this close to the weight, by the same source, is treated as the same measurement.
    public static let sameMeasurementTolerance: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - excludingOwnSamplesFrom: bundle identifiers whose `dietaryWater` contribution is subtracted and whose
    ///     weight and body fat samples are ignored — Vitalion's own, so what the app logged (and wrote to Health) is
    ///     not read back as data from other apps.
    ///   - localSampleIDs: the ids of the local rows those own samples may mirror (`HealthQuantitySample.externalID`).
    ///     When given, an own sample is ignored only when its external id is in the set; own samples without an id or
    ///     with an unknown one (written by an earlier install whose rows are gone) count like any other source's
    ///     data. Own water is told apart with `HealthDataBatch.waterSamples`; without them all own water is excluded.
    ///     Nil: every own sample is treated as local.
    public static func aggregate(
        _ batch: HealthDataBatch,
        calendar: Calendar = .current,
        excludingOwnSamplesFrom excludedSources: Set<String> = [],
        localSampleIDs: Set<String>? = nil,
    ) -> [DailyHealthMetrics] {
        let plan = HealthFetchPlan(days: batch.days, calendar: calendar)
        var days: [LocalDay: DailyHealthMetrics] = [:]
        for day in plan.allDays {
            days[day] = DailyHealthMetrics(day: day)
        }

        /// An own sample that mirrors a local row (and so must not be read back).
        let isLocal = { (sample: HealthQuantitySample) -> Bool in
            guard excludedSources.contains(sample.source.bundleIdentifier) else { return false }
            guard let localSampleIDs else { return true }
            return sample.externalID.map(localSampleIDs.contains) ?? false
        }

        // Own water without a local row, per day and source: it stays in the Health part of the day's water.
        var orphanWater: [LocalDay: [String: Double]] = [:]
        if localSampleIDs != nil, let waterSamples = batch.waterSamples {
            for sample in waterSamples where excludedSources.contains(sample.source.bundleIdentifier) && !isLocal(sample) {
                guard let day = plan.day(containing: sample.start) else { continue }
                orphanWater[day, default: [:]][sample.source.bundleIdentifier, default: 0] += sample.value
            }
        }

        for (metric, statistics) in batch.statistics {
            let isWater = metric == .dietaryWater
            apply(
                metric, statistics: statistics, plan: plan, excluding: isWater ? excludedSources : [],
                keeping: isWater ? orphanWater : [:], to: &days,
            )
        }

        let ownBody: Set<SampledMetric> = [.bodyMass, .bodyFatPercentage]
        let samplesByDay = batch.samples.reduce(into: [SampledMetric: [LocalDay?: [HealthQuantitySample]]]()) { result, entry in
            let samples = ownBody.contains(entry.key) ? entry.value.filter { !isLocal($0) } : entry.value
            result[entry.key] = Dictionary(grouping: samples) { plan.day(containing: $0.start) }
        }
        // Not grouped by day: another app's reading from the evening before counts for the next day.
        let hrvSamples = batch.samples[.heartRateVariabilitySDNN] ?? []
        for day in plan.allDays {
            let samples = { (metric: SampledMetric) in samplesByDay[metric]?[day] ?? [] }
            days[day]?.applyBody(weights: samples(.bodyMass), bodyFat: samples(.bodyFatPercentage))
            days[day]?.applyRestingHeartRate(samples(.restingHeartRate))
            days[day]?.applyHRV(hrvSamples.filter { sample in
                let window = hrvWindow(for: day, source: sample.source.kind, calendar: calendar)
                return sample.start >= window.start && sample.start < window.end
            })
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
        keeping orphans: [LocalDay: [String: Double]],
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
                let isOwn = { (contribution: SourceContribution) in excludedSources.contains(contribution.source.bundleIdentifier) }
                let excluded = sources.filter(isOwn)
                sources.removeAll(where: isOwn)
                // Own samples without a local row stay, under their source; only the rest is subtracted.
                var local = 0.0
                for contribution in excluded {
                    let orphan = min(orphans[day]?[contribution.source.bundleIdentifier] ?? 0, contribution.sum)
                    local += contribution.sum - orphan
                    if orphan > 0 {
                        sources.append(SourceContribution(source: contribution.source, sum: orphan))
                    }
                }
                guard excluded.isEmpty || !sources.isEmpty else { continue } // only our own, local samples
                // Per-source sums are taken before Health's de-duplication, so clamp at zero.
                total = max(0, total - local)
            }
            let merged = CumulativeStatistic(start: stats[0].start, end: stats[0].end, sum: total, sources: sources)
            let source = merged.mainSource?.name
            switch metric {
            case .steps:
                days[day]?.steps = DisplayRounding.whole(total)
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
