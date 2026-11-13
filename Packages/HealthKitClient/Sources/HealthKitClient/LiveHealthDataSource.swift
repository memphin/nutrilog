#if os(iOS)
    import Core
    import Foundation
    import HealthKit
    import Synchronization

    /// `HealthDataSource` backed by `HKHealthStore` (iOS only; needs the HealthKit entitlement).
    ///
    /// Queries per fetch (SPEC §3.4):
    /// - steps, active/basal energy, water: `HKStatisticsCollectionQuery` with `.cumulativeSum`, one bucket per
    ///   local day anchored at local midnight. The totals come from a query *without* `.separateBySource`, so
    ///   Health's de-duplication across iPhone and Watch applies; a second query with `.separateBySource` names the
    ///   main source for the source summary and lets Core leave Vitalion's own water out.
    /// - weight, body fat, resting heart rate, HRV: plain sample queries over the days, reduced in Core. Each sample
    ///   carries its `HKMetadataKeyExternalUUID`, so Core can tell the app's own samples that still have a local row.
    /// - the app's own water samples (with external ids), for the same reason (`HealthDataBatch.waterSamples`).
    /// - sleep: category samples whose end date falls inside the nights' windows.
    /// - workouts: every `HKWorkout` that started on the days, with its duration, active energy and distance.
    ///
    /// Statistics buckets follow the device calendar (`Calendar.current`), so pass that calendar in production.
    public final class LiveHealthDataSource: HealthDataSource {
        let store: HKHealthStore
        /// The running observer queries (backlog #26), replaced on every `startObserving`.
        let observerQueries = Mutex<[HKObserverQuery]>([])

        public init(store: HKHealthStore = HKHealthStore()) {
            self.store = store
        }

        public var isAvailable: Bool {
            HKHealthStore.isHealthDataAvailable()
        }

        /// Everything requested for reading: the full `HealthReadType` catalog.
        public static let readTypes = Set(HealthReadType.allCases.map(\.objectType))
        /// Everything requested for writing: the full `HealthWriteType` catalog.
        public static let shareTypes = Set<HKSampleType>(HealthWriteType.allCases.map(\.quantityType))

        // MARK: Authorization

        public func authorizationRequestStatus() async -> HealthAuthorizationRequestStatus {
            guard isAvailable else { return .unknown }
            do {
                switch try await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes) {
                case .shouldRequest: return .shouldRequest
                case .unnecessary: return .unnecessary
                case .unknown: return .unknown
                @unknown default: return .unknown
                }
            } catch {
                return .unknown
            }
        }

        public func requestAuthorization() async throws {
            guard isAvailable else { throw HealthDataError.unavailable }
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        }

        public func writeAuthorization(for type: HealthWriteType) async -> HealthWriteAuthorization {
            switch store.authorizationStatus(for: type.quantityType) {
            case .notDetermined: .notDetermined
            case .sharingDenied: .denied
            case .sharingAuthorized: .authorized
            @unknown default: .notDetermined
            }
        }

        // MARK: Daily data

        public func fetchDailyData(for days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> HealthDataBatch {
            guard isAvailable else { throw HealthDataError.unavailable }
            let plan = HealthFetchPlan(days: days, calendar: calendar)

            async let steps = statistics(.steps, plan: plan)
            async let active = statistics(.activeEnergy, plan: plan)
            async let basal = statistics(.basalEnergy, plan: plan)
            async let water = statistics(.dietaryWater, plan: plan)
            async let weights = samples(.bodyMass, plan: plan)
            async let bodyFat = samples(.bodyFatPercentage, plan: plan)
            async let restingHR = samples(.restingHeartRate, plan: plan)
            async let hrv = samples(.heartRateVariabilitySDNN, plan: plan)
            async let sleep = sleepSamples(plan: plan)
            async let ownWater = ownWaterSamples(plan: plan)
            async let workouts = workouts(plan: plan)

            return try await HealthDataBatch(
                days: days,
                statistics: [.steps: steps, .activeEnergy: active, .basalEnergy: basal, .dietaryWater: water],
                samples: [
                    .bodyMass: weights,
                    .bodyFatPercentage: bodyFat,
                    .restingHeartRate: restingHR,
                    .heartRateVariabilitySDNN: hrv,
                ],
                sleep: sleep,
                waterSamples: ownWater,
                workouts: workouts,
            )
        }

        private func statistics(_ metric: CumulativeMetric, plan: HealthFetchPlan) async throws -> [CumulativeStatistic] {
            let predicate = HKSamplePredicate.quantitySample(
                type: metric.quantityType,
                predicate: HKQuery.predicateForSamples(withStart: plan.dayInterval.start, end: plan.dayInterval.end),
            )
            let daily = DateComponents(day: 1)
            let totals = HKStatisticsCollectionQueryDescriptor(
                predicate: predicate, options: .cumulativeSum, anchorDate: plan.dayInterval.start, intervalComponents: daily,
            )
            let bySource = HKStatisticsCollectionQueryDescriptor(
                predicate: predicate, options: [.cumulativeSum, .separateBySource], anchorDate: plan.dayInterval.start,
                intervalComponents: daily,
            )
            async let totalCollection = totals.result(for: store)
            async let sourceCollection = bySource.result(for: store)
            let (collection, perSource) = try await (totalCollection, sourceCollection)

            let unit = metric.unit
            return collection.statistics().compactMap { stats -> CumulativeStatistic? in
                guard let sum = stats.sumQuantity() else { return nil }
                let split = perSource.statistics(for: stats.startDate)
                let contributions = (split?.sources ?? []).compactMap { source -> SourceContribution? in
                    guard let value = split?.sumQuantity(for: source) else { return nil }
                    return SourceContribution(source: HealthSource(source), sum: value.doubleValue(for: unit))
                }
                return CumulativeStatistic(
                    start: stats.startDate, end: stats.endDate, sum: sum.doubleValue(for: unit), sources: contributions,
                )
            }
        }

        private func samples(_ metric: SampledMetric, plan: HealthFetchPlan) async throws -> [HealthQuantitySample] {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(
                    type: metric.quantityType,
                    predicate: HKQuery.predicateForSamples(
                        withStart: plan.dayInterval.start, end: plan.dayInterval.end, options: .strictStartDate,
                    ),
                )],
                sortDescriptors: [SortDescriptor(\.startDate)],
            )
            let unit = metric.unit
            let scale = metric.valueScale
            return try await descriptor.result(for: store).map { sample in
                HealthQuantitySample(
                    start: sample.startDate,
                    end: sample.endDate,
                    value: sample.quantity.doubleValue(for: unit) * scale,
                    source: HealthSource(sample.sourceRevision),
                    externalID: sample.externalID,
                )
            }
        }

        /// This app's own `dietaryWater` samples with their external ids, so Core can tell water whose `water_entry`
        /// row still exists from water written by an earlier install. Only the app's own source is read: the totals and
        /// the other sources come from the statistics query.
        private func ownWaterSamples(plan: HealthFetchPlan) async throws -> [HealthQuantitySample] {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(
                    type: HKQuantityType(.dietaryWater),
                    predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                        HKQuery.predicateForSamples(
                            withStart: plan.dayInterval.start, end: plan.dayInterval.end, options: .strictStartDate,
                        ),
                        HKQuery.predicateForObjects(from: HKSource.default()),
                    ]),
                )],
                sortDescriptors: [SortDescriptor(\.startDate)],
            )
            let unit = CumulativeMetric.dietaryWater.unit
            return try await descriptor.result(for: store).map { sample in
                HealthQuantitySample(
                    start: sample.startDate,
                    end: sample.endDate,
                    value: sample.quantity.doubleValue(for: unit),
                    source: HealthSource(sample.sourceRevision),
                    externalID: sample.externalID,
                )
            }
        }

        private func sleepSamples(plan: HealthFetchPlan) async throws -> [SleepSample] {
            // Night membership is decided by the end date (SPEC §3.4). `.strictEndDate` is half-open, so the query
            // runs to one second past the last night's end; Core then applies the exact (start, end] windows.
            let query = plan.sleepQueryInterval
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.categorySample(
                    type: HKCategoryType(.sleepAnalysis),
                    predicate: HKQuery.predicateForSamples(withStart: query.start, end: query.end, options: .strictEndDate),
                )],
                sortDescriptors: [SortDescriptor(\.startDate)],
            )
            return try await descriptor.result(for: store).compactMap { sample in
                guard let stage = SleepStage(sleepAnalysisValue: sample.value) else { return nil }
                return SleepSample(start: sample.startDate, end: sample.endDate, stage: stage, source: HealthSource(sample.sourceRevision))
            }
        }

        /// The workouts that started on the plan's days, oldest first. Energy is the workout's active energy; the
        /// distance is the first of the distance types the workout has, else its total distance (workouts saved the
        /// old way carry only that).
        private func workouts(plan: HealthFetchPlan) async throws -> [HealthWorkout] {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.workout(HKQuery.predicateForSamples(
                    withStart: plan.dayInterval.start, end: plan.dayInterval.end, options: .strictStartDate,
                ))],
                sortDescriptors: [SortDescriptor(\.startDate)],
            )
            return try await descriptor.result(for: store).map { workout in
                let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
                let distance = Self.distanceTypes.lazy
                    .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity() }
                    .first ?? workout.totalDistance
                return HealthWorkout(
                    id: workout.uuid.uuidString.lowercased(),
                    day: LocalDay(workout.startDate, calendar: plan.calendar),
                    activityType: Int(workout.workoutActivityType.rawValue),
                    start: workout.startDate,
                    end: workout.endDate,
                    durationSec: workout.duration,
                    activeKcal: energy?.doubleValue(for: .kilocalorie()),
                    distanceM: distance?.doubleValue(for: .meter()),
                    source: HealthSource(workout.sourceRevision),
                )
            }
        }

        /// The distance a workout may carry, most common first.
        private static let distanceTypes: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
            .distanceCrossCountrySkiing, .distanceRowing, .distancePaddleSports, .distanceSkatingSports,
        ]

        // MARK: Characteristics

        public func fetchCharacteristics() async throws -> HealthCharacteristics {
            guard isAvailable else { throw HealthDataError.unavailable }
            var result = HealthCharacteristics()
            // Characteristic reads throw when not shared; that is the same as "no value".
            if let components = try? store.dateOfBirthComponents(),
               let year = components.year, let month = components.month, let day = components.day
            {
                result.dateOfBirth = LocalDay(year: year, month: month, day: day)
            }
            if let sex = try? store.biologicalSex().biologicalSex {
                result.sex = switch sex {
                case .male: .male
                case .female: .female
                case .other: .other
                default: nil
                }
            }
            let height = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(.height))],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                limit: 1,
            )
            if let latest = try await height.result(for: store).first {
                result.heightCm = latest.quantity.doubleValue(for: .meterUnit(with: .centi))
            }
            return result
        }
    }

    // MARK: - HealthKit mapping

    public extension HealthReadType {
        var objectType: HKObjectType {
            switch self {
            case .stepCount: HKQuantityType(.stepCount)
            case .activeEnergyBurned: HKQuantityType(.activeEnergyBurned)
            case .basalEnergyBurned: HKQuantityType(.basalEnergyBurned)
            case .sleepAnalysis: HKCategoryType(.sleepAnalysis)
            case .bodyMass: HKQuantityType(.bodyMass)
            case .bodyFatPercentage: HKQuantityType(.bodyFatPercentage)
            case .restingHeartRate: HKQuantityType(.restingHeartRate)
            case .heartRateVariabilitySDNN: HKQuantityType(.heartRateVariabilitySDNN)
            case .dietaryWater: HKQuantityType(.dietaryWater)
            case .workout: HKObjectType.workoutType()
            case .height: HKQuantityType(.height)
            case .dateOfBirth: HKCharacteristicType(.dateOfBirth)
            case .biologicalSex: HKCharacteristicType(.biologicalSex)
            }
        }
    }

    public extension HealthWriteType {
        var quantityType: HKQuantityType {
            switch self {
            case .dietaryEnergyConsumed: HKQuantityType(.dietaryEnergyConsumed)
            case .dietaryProtein: HKQuantityType(.dietaryProtein)
            case .dietaryCarbohydrates: HKQuantityType(.dietaryCarbohydrates)
            case .dietaryFatTotal: HKQuantityType(.dietaryFatTotal)
            case .dietaryFiber: HKQuantityType(.dietaryFiber)
            case .dietarySugar: HKQuantityType(.dietarySugar)
            case .dietarySodium: HKQuantityType(.dietarySodium)
            case .dietaryWater: HKQuantityType(.dietaryWater)
            case .bodyMass: HKQuantityType(.bodyMass)
            case .bodyFatPercentage: HKQuantityType(.bodyFatPercentage)
            }
        }
    }

    public extension CumulativeMetric {
        var quantityType: HKQuantityType {
            switch self {
            case .steps: HKQuantityType(.stepCount)
            case .activeEnergy: HKQuantityType(.activeEnergyBurned)
            case .basalEnergy: HKQuantityType(.basalEnergyBurned)
            case .dietaryWater: HKQuantityType(.dietaryWater)
            }
        }

        /// The unit of `CumulativeStatistic.sum` (`unitSymbol`).
        var unit: HKUnit {
            switch self {
            case .steps: .count()
            case .activeEnergy, .basalEnergy: .kilocalorie()
            case .dietaryWater: .literUnit(with: .milli)
            }
        }
    }

    public extension SampledMetric {
        var quantityType: HKQuantityType {
            switch self {
            case .bodyMass: HKQuantityType(.bodyMass)
            case .bodyFatPercentage: HKQuantityType(.bodyFatPercentage)
            case .restingHeartRate: HKQuantityType(.restingHeartRate)
            case .heartRateVariabilitySDNN: HKQuantityType(.heartRateVariabilitySDNN)
            }
        }

        var unit: HKUnit {
            switch self {
            case .bodyMass: .gramUnit(with: .kilo)
            case .bodyFatPercentage: .percent()
            case .restingHeartRate: .count().unitDivided(by: .minute())
            case .heartRateVariabilitySDNN: .secondUnit(with: .milli)
            }
        }

        /// Health stores body fat as a fraction (0.182); Vitalion uses percent (18.2).
        var valueScale: Double {
            self == .bodyFatPercentage ? 100 : 1
        }
    }

    public extension SleepStage {
        init?(sleepAnalysisValue value: Int) {
            switch HKCategoryValueSleepAnalysis(rawValue: value) {
            case .inBed: self = .inBed
            case .asleepUnspecified: self = .asleepUnspecified
            case .asleepCore: self = .asleepCore
            case .asleepDeep: self = .asleepDeep
            case .asleepREM: self = .asleepREM
            case .awake: self = .awake
            default: return nil
            }
        }
    }

    extension HKObject {
        /// `HKMetadataKeyExternalUUID`: Vitalion writes the id of the row a sample mirrors there.
        var externalID: String? {
            metadata?[HKMetadataKeyExternalUUID] as? String
        }
    }

    extension HealthSource {
        init(_ source: HKSource) {
            self.init(name: source.name, bundleIdentifier: source.bundleIdentifier)
        }

        init(_ revision: HKSourceRevision) {
            self.init(name: revision.source.name, bundleIdentifier: revision.source.bundleIdentifier, productType: revision.productType)
        }
    }
#endif
