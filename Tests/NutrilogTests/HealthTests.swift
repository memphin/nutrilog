import Core
import Foundation
import HealthKit
import HealthKitClient
import Persistence
import Testing
@testable import Nutrilog

@MainActor
struct HealthSyncServiceTests {
    let clock = ManualClock()

    /// An environment whose fake Health has demo data but has not been authorized yet.
    func makeEnvironment(authorized: Bool = false) -> (AppEnvironment, FakeHealthDataSource) {
        let today = LocalDay.today(now: clock.appClock.now())
        let fake = FakeHealthDataSource.demo(endingOn: today, days: 120)
        fake.update { $0.authorizationRequested = authorized }
        return (AppEnvironment.preview(clock: clock.appClock, health: fake), fake)
    }

    @Test func `nothing is read before the user is asked`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        await sync.refresh(force: true)
        #expect(fake.snapshot.fetchedRanges.isEmpty)
        #expect(!sync.isBackfillComplete)
        #expect(sync.lastSyncedAt == nil)
    }

    @Test func `first authorization backfills the last 90 days newest first`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        let today = sync.today
        try await sync.connect()

        #expect(fake.snapshot.authorizationRequestCount == 1)
        #expect(fake.snapshot.fetchedRanges == [
            today.adding(days: -29) ... today,
            today.adding(days: -59) ... today.adding(days: -30),
            today.adding(days: -89) ... today.adding(days: -60),
        ])
        let rows = try #require(try env.dailyMetrics?.metrics(in: sync.window))
        #expect(rows.count == 90)
        #expect(rows.first?.day == today.adding(days: -89))
        #expect(rows.allSatisfy { $0.weightKg != nil && $0.steps != nil && $0.sleepAsleepMin != nil })
        #expect(try env.dailyMetrics?.metrics(on: today.adding(days: -90)) == nil) // outside the window
        #expect(sync.isBackfillComplete)
        #expect(sync.phase == .idle)
        #expect(sync.lastSyncedAt == clock.appClock.now())
        #expect(try env.profiles?.setting(SettingKey.healthLastSyncedDay, as: LocalDay.self) == today)
    }

    @Test func `source summary records the device of each metric`() async throws {
        let (env, _) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await sync.connect()
        let row = try #require(try env.dailyMetrics?.metrics(on: sync.today))
        let sources = DailyHealthMetrics.sources(fromJSON: row.sourceSummary)
        #expect(sources[.weight] == "Withings")
        #expect(sources[.bodyFat] == "Withings")
        #expect(sources[.steps] == "Apple Watch")
        #expect(sources[.sleep] == "Apple Watch")
        #expect(sources[.hrv] == "Apple Watch")
        #expect(sources[.water] == "iPhone")
    }

    @Test func `refresh reads the recent days and is throttled`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await sync.connect()
        let backfillFetches = fake.snapshot.fetchedRanges.count

        await sync.refresh() // right after the backfill: skipped
        #expect(fake.snapshot.fetchedRanges.count == backfillFetches)

        clock.advance(hours: 24)
        await sync.refresh()
        let today = sync.today
        #expect(fake.snapshot.fetchedRanges.last == today.adding(days: -2) ... today)

        await sync.refresh(force: true) // pull to refresh ignores the throttle
        #expect(fake.snapshot.fetchedRanges.count == backfillFetches + 2)
    }

    @Test func `refresh after a long absence covers every missed day`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await sync.connect()
        let lastSync = sync.today
        clock.advance(hours: 24 * 10)
        await sync.refresh()
        #expect(fake.snapshot.fetchedRanges.last == lastSync ... sync.today)
        #expect(try env.dailyMetrics?.metrics(in: sync.window).count == 90)
    }

    @Test func `access granted on a previous install triggers the backfill`() async throws {
        let (env, fake) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.refresh()
        #expect(fake.snapshot.authorizationRequestCount == 0)
        #expect(fake.snapshot.fetchedRanges.count == 3)
        #expect(sync.isBackfillComplete)
    }

    @Test func `a failed backfill is reported and retried`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        fake.update { $0.fetchError = HealthDataError.unavailable }
        try await sync.connect()
        guard case .failed = sync.phase else {
            Issue.record("expected a failure, got \(sync.phase)")
            return
        }
        #expect(!sync.isBackfillComplete)

        fake.update { $0.fetchError = nil }
        await sync.refresh(force: true)
        #expect(sync.phase == .idle)
        #expect(sync.isBackfillComplete)
        #expect(try env.dailyMetrics?.metrics(in: sync.window).count == 90)
    }

    @Test func `concurrent refreshes run one sync`() async throws {
        let (env, fake) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        async let first: Void = sync.refresh()
        async let second: Void = sync.refresh()
        _ = await (first, second)
        #expect(fake.snapshot.fetchedRanges.count == 3) // one backfill, not two
    }

    @Test func `days whose data disappeared from Health are emptied`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await sync.connect()
        fake.update { $0.samples[.bodyMass] = [] }
        await sync.refresh(force: true)
        #expect(try env.dailyMetrics?.metrics(on: sync.today)?.weightKg == nil)
        #expect(try env.dailyMetrics?.metrics(on: sync.today)?.steps != nil)
    }
}

@MainActor
struct HealthPermissionTests {
    @Test func `denied reads show no data for every type`() async throws {
        let fake = FakeHealthDataSource.demo(endingOn: LocalDay.today(), days: 30)
        fake.update {
            $0.authorizationRequested = false
            $0.readAllowed = false
        }
        let env = AppEnvironment.preview(health: fake)
        let sync = try #require(env.healthSync)
        try await sync.connect()
        let rows = try #require(try env.dailyMetrics?.metrics(in: sync.window))
        #expect(rows.count == 90)
        let allEmpty = rows.allSatisfy(\.metrics.isEmpty)
        #expect(allEmpty)

        let model = HealthSettingsModel()
        await model.load(environment: env)
        #expect(model.isConnected)
        #expect(HealthReadType.allCases.allSatisfy { model.statuses[$0] == .noData })
    }

    @Test func `settings show the source of found data`() async {
        let env = AppEnvironment.preview(sampleData: true)
        await env.healthSync?.refresh()
        let model = HealthSettingsModel()
        await model.load(environment: env)
        #expect(model.statuses[.bodyMass] == .found(source: "Withings"))
        #expect(model.statuses[.sleepAnalysis] == .found(source: "Apple Watch"))
        #expect(model.statuses[.height] == .found(source: nil))
        #expect(HealthReadType.allCases.allSatisfy { model.statuses[$0] != .noData })
    }

    @Test func `not connected yet shows no statuses`() async {
        let env = AppEnvironment.preview()
        let model = HealthSettingsModel()
        await model.load(environment: env)
        #expect(!model.isConnected)
        #expect(model.requestStatus == .shouldRequest)
        #expect(model.statuses.isEmpty)
    }

    @Test func `first launch onboarding is offered once`() async {
        let env = AppEnvironment.preview()
        let firstLaunch = await env.shouldShowHealthOnboarding()
        #expect(firstLaunch)
        env.markHealthOnboardingShown()
        let secondLaunch = await env.shouldShowHealthOnboarding()
        #expect(!secondLaunch)

        let connected = await AppEnvironment.preview(sampleData: true).shouldShowHealthOnboarding()
        #expect(!connected)

        let noHealth = await AppEnvironment.preview(health: FakeHealthDataSource(isAvailable: false)).shouldShowHealthOnboarding()
        #expect(!noHealth)
    }
}

struct HealthKitMappingTests {
    @Test func `catalog maps to the matching HealthKit types`() {
        for type in HealthReadType.allCases {
            #expect(type.objectType.identifier == type.identifier, "\(type)")
        }
        for type in HealthWriteType.allCases {
            #expect(type.quantityType.identifier == type.identifier, "\(type)")
        }
        let readIdentifiers = Set(HealthReadType.allCases.map(\.identifier))
        for metric in CumulativeMetric.allCases {
            #expect(readIdentifiers.contains(metric.quantityType.identifier), "\(metric)")
            #expect(metric.quantityType.is(compatibleWith: metric.unit), "\(metric)")
        }
        for metric in SampledMetric.allCases {
            #expect(readIdentifiers.contains(metric.quantityType.identifier), "\(metric)")
            #expect(metric.quantityType.is(compatibleWith: metric.unit), "\(metric)")
        }
        #expect(SampledMetric.bodyFatPercentage.valueScale == 100)
        #expect(LiveHealthDataSource.readTypes.count == 12)
        #expect(LiveHealthDataSource.shareTypes.count == 9)
    }

    @Test func `sleep values map to stages`() {
        let mapped = [
            HKCategoryValueSleepAnalysis.inBed, .asleepUnspecified, .awake, .asleepCore, .asleepDeep, .asleepREM,
        ].map { SleepStage(sleepAnalysisValue: $0.rawValue) }
        #expect(mapped == [.inBed, .asleepUnspecified, .awake, .asleepCore, .asleepDeep, .asleepREM])
        #expect(SleepStage(sleepAnalysisValue: 999) == nil)
    }
}
