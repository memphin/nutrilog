import Core
import Foundation
import Testing
@testable import HealthKitClient
#if canImport(HealthKit)
    import HealthKit
#endif

private func calendar(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private let zagreb = calendar("Europe/Zagreb")
private let watch = HealthSource(name: "Ivan's Apple Watch", bundleIdentifier: "com.apple.health.W1", productType: "Watch7,1")
private let phone = HealthSource(name: "jaPhone", bundleIdentifier: "com.apple.health.P1", productType: "iPhone17,1")

private func day(_ string: String) -> LocalDay {
    LocalDay(string)!
}

private func at(_ dayString: String, _ hour: Int, _ minute: Int = 0) -> Date {
    day(dayString).date(atHour: hour, calendar: zagreb).addingTimeInterval(TimeInterval(minute * 60))
}

struct HealthTypeCatalogTests {
    @Test func `catalog lists the SPEC read and write types`() {
        #expect(HealthReadType.allCases.count == 12)
        #expect(HealthWriteType.allCases.count == 10)
        #expect(Set(HealthReadType.allCases.compactMap(\.metric)) == Set(HealthMetric.allCases))
        #expect(HealthReadType.allCases.filter { $0.kind == .characteristic } == [.dateOfBirth, .biologicalSex])
        #expect(HealthReadType.allCases.filter { $0.kind == .category } == [.sleepAnalysis])
        #expect(Set(HealthReadType.allCases.compactMap(\.cumulativeMetric)) == Set(CumulativeMetric.allCases))
        #expect(Set(HealthReadType.allCases.compactMap(\.sampledMetric)) == Set(SampledMetric.allCases))
    }

    @Test func `every type is explained before the permission sheet`() {
        for type in HealthReadType.allCases {
            #expect(!type.title.isEmpty && type.explanation.count > 20, "\(type)")
            #expect(type.id == type.rawValue)
        }
        for type in HealthWriteType.allCases {
            #expect(!type.title.isEmpty && type.explanation.count > 20, "\(type)")
        }
        #expect(HealthWriteType.dietaryProtein.explanation.hasPrefix("The protein of each diary entry"))
        #expect(Set(HealthReadType.allCases.map(\.title)).count == 12)
    }

    @Test func `identifiers match HealthKit`() {
        #expect(HealthReadType.stepCount.identifier == "HKQuantityTypeIdentifierStepCount")
        #expect(HealthReadType.sleepAnalysis.identifier == "HKCategoryTypeIdentifierSleepAnalysis")
        #expect(HealthReadType.biologicalSex.identifier == "HKCharacteristicTypeIdentifierBiologicalSex")
        #expect(HealthWriteType.dietaryFatTotal.identifier == "HKQuantityTypeIdentifierDietaryFatTotal")
        #if canImport(HealthKit)
            let reads: [HealthReadType: String] = [
                .stepCount: HKQuantityTypeIdentifier.stepCount.rawValue,
                .activeEnergyBurned: HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                .basalEnergyBurned: HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
                .sleepAnalysis: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                .bodyMass: HKQuantityTypeIdentifier.bodyMass.rawValue,
                .bodyFatPercentage: HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
                .restingHeartRate: HKQuantityTypeIdentifier.restingHeartRate.rawValue,
                .heartRateVariabilitySDNN: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                .dietaryWater: HKQuantityTypeIdentifier.dietaryWater.rawValue,
                .height: HKQuantityTypeIdentifier.height.rawValue,
                .dateOfBirth: HKCharacteristicTypeIdentifier.dateOfBirth.rawValue,
                .biologicalSex: HKCharacteristicTypeIdentifier.biologicalSex.rawValue,
            ]
            for type in HealthReadType.allCases {
                #expect(type.identifier == reads[type], "\(type)")
            }
            let writes: [HealthWriteType: String] = [
                .dietaryEnergyConsumed: HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue,
                .dietaryProtein: HKQuantityTypeIdentifier.dietaryProtein.rawValue,
                .dietaryCarbohydrates: HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
                .dietaryFatTotal: HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
                .dietaryFiber: HKQuantityTypeIdentifier.dietaryFiber.rawValue,
                .dietarySugar: HKQuantityTypeIdentifier.dietarySugar.rawValue,
                .dietarySodium: HKQuantityTypeIdentifier.dietarySodium.rawValue,
                .dietaryWater: HKQuantityTypeIdentifier.dietaryWater.rawValue,
                .bodyMass: HKQuantityTypeIdentifier.bodyMass.rawValue,
                .bodyFatPercentage: HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
            ]
            for type in HealthWriteType.allCases {
                #expect(type.identifier == writes[type], "\(type)")
            }
        #endif
    }

    @Test func `characteristics report which types have values`() {
        let characteristics = HealthCharacteristics(heightCm: 181, dateOfBirth: nil, sex: .male)
        #expect(characteristics.hasValue(for: .height) == true)
        #expect(characteristics.hasValue(for: .dateOfBirth) == false)
        #expect(characteristics.hasValue(for: .biologicalSex) == true)
        #expect(characteristics.hasValue(for: .stepCount) == nil)
        #expect(HealthKitClient.noDataMessage == "No data found — check Health permissions")
    }
}

struct FakeHealthDataSourceTests {
    @Test func `authorization flow`() async throws {
        let fake = FakeHealthDataSource()
        #expect(await fake.authorizationRequestStatus() == .shouldRequest)
        #expect(await fake.writeAuthorization(for: .dietaryWater) == .notDetermined)
        try await fake.requestAuthorization()
        #expect(await fake.authorizationRequestStatus() == .unnecessary)
        #expect(await fake.writeAuthorization(for: .dietaryWater) == .authorized)
        fake.update { $0.writeAllowed = false }
        #expect(await fake.writeAuthorization(for: .bodyMass) == .denied)
        #expect(fake.snapshot.authorizationRequestCount == 1)
    }

    @Test func `authorization error is thrown once`() async {
        let fake = FakeHealthDataSource()
        fake.update { $0.authorizationError = HealthDataError.unavailable }
        await #expect(throws: HealthDataError.unavailable) { try await fake.requestAuthorization() }
        #expect(await fake.authorizationRequestStatus() == .shouldRequest)
        await #expect(throws: Never.self) { try await fake.requestAuthorization() }
        #expect(await fake.authorizationRequestStatus() == .unnecessary)
    }

    @Test func `unavailable device`() async {
        let fake = FakeHealthDataSource(isAvailable: false)
        #expect(!fake.isAvailable)
        #expect(await fake.authorizationRequestStatus() == .unknown)
        await #expect(throws: HealthDataError.unavailable) { try await fake.requestAuthorization() }
        await #expect(throws: HealthDataError.unavailable) {
            try await fake.fetchDailyData(for: day("2026-11-09") ... day("2026-11-09"), calendar: zagreb)
        }
        await #expect(throws: HealthDataError.unavailable) { try await fake.fetchCharacteristics() }
    }

    @Test func `cumulative samples become one statistic per local day`() async throws {
        var state = FakeHealthDataSource.State()
        state.cumulativeSamples[.steps] = [
            HealthQuantitySample(start: at("2026-03-29", 0, 30), value: 1000, source: watch), // DST day, 23 h
            HealthQuantitySample(start: at("2026-03-29", 23, 30), value: 2000, source: phone),
            HealthQuantitySample(start: at("2026-03-30", 9), value: 500, source: watch),
            HealthQuantitySample(start: at("2026-03-31", 9), value: 700, source: watch), // outside the range
        ]
        let fake = FakeHealthDataSource(state: state)
        let batch = try await fake.fetchDailyData(for: day("2026-03-29") ... day("2026-03-30"), calendar: zagreb)
        let steps = try #require(batch.statistics[.steps])
        #expect(steps.count == 2)
        #expect(steps[0].sum == 3000)
        #expect(steps[0].end.timeIntervalSince(steps[0].start) == 82800)
        #expect(steps[0].mainSource == phone)
        #expect(steps[1].sum == 500)
        #expect(fake.snapshot.fetchedRanges == [day("2026-03-29") ... day("2026-03-30")])

        let metrics = DailyMetricsAggregator.aggregate(batch, calendar: zagreb)
        #expect(metrics.map(\.steps) == [3000, 500])
    }

    @Test func `samples and sleep are limited to the requested days`() async throws {
        var state = FakeHealthDataSource.State()
        state.samples[.bodyMass] = [
            HealthQuantitySample(start: at("2026-11-08", 7), value: 82.0, source: watch),
            HealthQuantitySample(start: at("2026-11-09", 7), value: 81.8, source: watch),
        ]
        state.sleep = [
            SleepSample(start: at("2026-11-07", 23), end: at("2026-11-08", 7), stage: .asleepCore, source: watch),
            SleepSample(start: at("2026-11-08", 23), end: at("2026-11-09", 7), stage: .asleepCore, source: watch),
        ]
        let fake = FakeHealthDataSource(state: state)
        let batch = try await fake.fetchDailyData(for: day("2026-11-09") ... day("2026-11-09"), calendar: zagreb)
        #expect(batch.samples[.bodyMass]?.map(\.value) == [81.8])
        #expect(batch.sleep.count == 1)
    }

    @Test func `after a reinstall, own samples with no local row are read like any other source`() async throws {
        let own = HealthSource(name: "Vitalion", bundleIdentifier: "hr.ivanjuric.nutrilog", productType: "iPhone17,1")
        var state = FakeHealthDataSource.State()
        state.samples[.bodyMass] = [
            HealthQuantitySample(start: at("2026-11-09", 7), value: 81.8, source: own, externalID: "gone"),
            HealthQuantitySample(start: at("2026-11-10", 7), value: 81.5, source: own, externalID: "local-w"),
        ]
        state.cumulativeSamples[.dietaryWater] = [
            HealthQuantitySample(start: at("2026-11-09", 9), value: 500, source: own, externalID: "gone-water"),
            HealthQuantitySample(start: at("2026-11-10", 9), value: 300, source: own, externalID: "local-water"),
            HealthQuantitySample(start: at("2026-11-10", 10), value: 200, source: phone),
            HealthQuantitySample(start: at("2026-11-11", 9), value: 999, source: own, externalID: "x"), // outside
        ]
        let fake = FakeHealthDataSource(state: state)
        let batch = try await fake.fetchDailyData(for: day("2026-11-09") ... day("2026-11-10"), calendar: zagreb)
        #expect(batch.samples[.bodyMass]?.map(\.externalID) == ["gone", "local-w"])
        #expect(batch.waterSamples?.count == 3)

        let rows = DailyMetricsAggregator.aggregate(
            batch, calendar: zagreb, excludingOwnSamplesFrom: [own.bundleIdentifier], localSampleIDs: ["local-w", "local-water"],
        )
        #expect(rows.map(\.weightKg) == [81.8, nil])
        #expect(rows.map(\.waterMl) == [500, 200])
        #expect(rows[0].sources[.weight] == "Vitalion")
    }

    @Test func `denied reads look exactly like no data`() async throws {
        let fake = FakeHealthDataSource.demo(endingOn: day("2026-11-09"), days: 5, calendar: zagreb)
        fake.update { $0.readAllowed = false }
        let batch = try await fake.fetchDailyData(for: day("2026-11-05") ... day("2026-11-09"), calendar: zagreb)
        #expect(batch == HealthDataBatch(days: day("2026-11-05") ... day("2026-11-09")))
        #expect(try await fake.fetchCharacteristics() == HealthCharacteristics())
    }

    @Test func `fetch errors are thrown`() async {
        let fake = FakeHealthDataSource()
        fake.update { $0.fetchError = HealthDataError.unavailable }
        await #expect(throws: HealthDataError.unavailable) {
            try await fake.fetchDailyData(for: day("2026-11-09") ... day("2026-11-09"), calendar: zagreb)
        }
    }

    @Test func `fetch errors can start after some successful fetches`() async throws {
        let fake = FakeHealthDataSource()
        fake.update {
            $0.fetchError = HealthDataError.unavailable
            $0.fetchErrorAfter = 1
        }
        let days = day("2026-11-09") ... day("2026-11-09")
        _ = try await fake.fetchDailyData(for: days, calendar: zagreb)
        await #expect(throws: HealthDataError.unavailable) { try await fake.fetchDailyData(for: days, calendar: zagreb) }
        #expect(fake.snapshot.fetchedTimeZones == [zagreb.timeZone, zagreb.timeZone])
    }

    @Test func `a nap ending exactly at 18 00 on the last day is fetched`() async throws {
        // HealthKit's `.strictEndDate` is half-open; the query runs one second longer so this sample survives.
        let nap = SleepSample(start: at("2026-11-09", 17), end: at("2026-11-09", 18), stage: .asleepCore, source: watch)
        let lastNightEnd = day("2026-11-08").date(atHour: 18, calendar: zagreb)
        let previousNight = SleepSample(start: at("2026-11-08", 17), end: lastNightEnd, stage: .asleepCore, source: watch)
        let fake = FakeHealthDataSource()
        fake.update { $0.sleep = [nap, previousNight] }

        let days = day("2026-11-09") ... day("2026-11-09")
        let plan = HealthFetchPlan(days: days, calendar: zagreb)
        #expect(plan.sleepQueryInterval.end.timeIntervalSince(plan.sleepInterval.end) == 1)
        let batch = try await fake.fetchDailyData(for: days, calendar: zagreb)
        #expect(batch.sleep.contains(nap))

        // The previous night's sample also matches the query start, but Core keeps it out of this night.
        let metrics = DailyMetricsAggregator.aggregate(batch, calendar: zagreb)
        #expect(metrics.first?.sleepAsleepMin == 60)
    }

    @Test func `demo data fills every metric`() async throws {
        let fake = FakeHealthDataSource.demo(endingOn: day("2026-11-09"), days: 10, calendar: zagreb)
        #expect(await fake.authorizationRequestStatus() == .unnecessary)
        let batch = try await fake.fetchDailyData(for: day("2026-11-01") ... day("2026-11-09"), calendar: zagreb)
        let metrics = DailyMetricsAggregator.aggregate(batch, calendar: zagreb)
        #expect(metrics.count == 9)
        for row in metrics {
            #expect(HealthMetric.allCases.allSatisfy { row.hasValue($0) }, "\(row.day)")
            #expect(row.sources[.sleep] == "Apple Watch")
            #expect(row.sources[.weight] == "Withings")
        }
        let characteristics = try await fake.fetchCharacteristics()
        #expect(characteristics.heightCm == 181)
        #expect(characteristics.sex == .male)
    }
}
