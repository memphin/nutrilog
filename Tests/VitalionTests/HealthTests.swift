import Core
import Foundation
import HealthKit
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

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

    /// Connects (permission sheet) and waits for the background sync it starts.
    func connect(_ sync: HealthSyncService) async throws {
        try await sync.connect()
        await sync.waitForSync()
    }

    func fullWindowChunks(endingOn today: LocalDay) -> [ClosedRange<LocalDay>] {
        [
            today.adding(days: -29) ... today,
            today.adding(days: -59) ... today.adding(days: -30),
            today.adding(days: -89) ... today.adding(days: -60),
        ]
    }

    @Test func `nothing is read before the user is asked`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        await sync.refresh(force: true)
        await env.systemTimeDidChange()
        #expect(fake.snapshot.fetchedRanges.isEmpty)
        #expect(!sync.isBackfillComplete)
        #expect(sync.lastSyncedAt == nil)
    }

    @Test func `connect returns after the permission sheet and backfills 90 days in the background`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        let today = sync.today
        try await sync.connect()
        #expect(sync.isSyncing) // the sheet can close while the backfill runs
        await sync.waitForSync()

        #expect(fake.snapshot.authorizationRequestCount == 1)
        #expect(fake.snapshot.fetchedRanges == fullWindowChunks(endingOn: today))
        let rows = try #require(try env.dailyMetrics?.metrics(in: sync.window))
        #expect(rows.count == 90)
        #expect(rows.first?.day == today.adding(days: -89))
        #expect(rows.allSatisfy { $0.weightKg != nil && $0.steps != nil && $0.sleepAsleepMin != nil })
        #expect(try env.dailyMetrics?.metrics(on: today.adding(days: -90)) == nil) // outside the window
        #expect(sync.isBackfillComplete)
        #expect(sync.phase == .idle)
        let now = clock.appClock.now()
        #expect(sync.lastSyncedAt == now)
        #expect(sync.lastFullSyncAt == now)
        #expect(try env.profiles?.setting(SettingKey.healthLastSyncedAt, as: Date.self) == now)
        #expect(try env.profiles?.setting(SettingKey.healthLastFullSyncAt, as: Date.self) == now)
    }

    @Test func `source summary records the device of each metric`() async throws {
        let (env, _) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await connect(sync)
        let row = try #require(try env.dailyMetrics?.metrics(on: sync.today))
        let sources = DailyHealthMetrics.sources(fromJSON: row.sourceSummary)
        #expect(sources[.weight] == "Withings")
        #expect(sources[.bodyFat] == "Withings")
        #expect(sources[.steps] == "Apple Watch")
        #expect(sources[.sleep] == "Apple Watch")
        #expect(sources[.hrv] == "Apple Watch")
        #expect(sources[.water] == "iPhone")
    }

    @Test func `automatic refresh reads the recent days and is throttled, forced refresh the full window`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await connect(sync)
        let backfillFetches = fake.snapshot.fetchedRanges.count

        await sync.refresh() // right after the backfill: skipped
        #expect(fake.snapshot.fetchedRanges.count == backfillFetches)

        clock.advance(hours: 6)
        await sync.refresh()
        let today = sync.today
        #expect(fake.snapshot.fetchedRanges.last == today.adding(days: -2) ... today)

        await sync.refresh(force: true) // Update now / pull to refresh: full window, no throttle
        #expect(Array(fake.snapshot.fetchedRanges.suffix(3)) == fullWindowChunks(endingOn: today))
        #expect(fake.snapshot.fetchedRanges.count == backfillFetches + 4)
    }

    @Test func `the full window is re-read automatically once a day`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        try await connect(sync)
        clock.advance(hours: 25)
        await sync.refresh()
        #expect(Array(fake.snapshot.fetchedRanges.suffix(3)) == fullWindowChunks(endingOn: sync.today))
        #expect(try env.dailyMetrics?.metrics(in: sync.window).count == 90)
        #expect(sync.lastFullSyncAt == clock.appClock.now())
    }

    @Test func `read access granted after the backfill fills the history`() async throws {
        let (env, fake) = makeEnvironment()
        fake.update { $0.readAllowed = false }
        let sync = try #require(env.healthSync)
        try await connect(sync)
        let repository = try #require(env.dailyMetrics)
        #expect(try repository.metrics(in: sync.window).allSatisfy { row in
            !HealthMetric.allCases.contains { row.metrics.hasValue($0) }
        })

        // The user allows reading in the Health app later.
        fake.update { $0.readAllowed = true }
        clock.advance(hours: 1)
        await sync.refresh()
        #expect(try repository.metrics(on: sync.today)?.weightKg != nil)
        #expect(try repository.metrics(on: sync.today.adding(days: -10))?.weightKg == nil) // only the recent days so far

        await sync.refresh(force: true) // Update now
        let rows = try repository.metrics(in: sync.window)
        #expect(rows.count == 90)
        #expect(rows.allSatisfy { $0.weightKg != nil && $0.sleepAsleepMin != nil })
    }

    @Test func `a weight uploaded late for ten days ago is picked up by the daily full sync`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        let lateDay = sync.today.adding(days: -10)
        let late = try #require(fake.snapshot.samples[.bodyMass]?.first { LocalDay($0.start) == lateDay })
        fake.update { $0.samples[.bodyMass]?.removeAll { LocalDay($0.start) == lateDay } }
        try await connect(sync)
        let repository = try #require(env.dailyMetrics)
        #expect(try repository.metrics(on: lateDay)?.weightKg == nil)

        // The scale syncs days later.
        fake.update { $0.samples[.bodyMass]?.append(late) }
        clock.advance(hours: 1)
        await sync.refresh()
        #expect(try repository.metrics(on: lateDay)?.weightKg == nil) // recent days only

        clock.advance(hours: 24)
        await sync.refresh()
        #expect(try repository.metrics(on: lateDay)?.weightKg == late.value)
        #expect(try repository.metrics(on: lateDay)?.sourceSummary?.contains("Withings") == true)
    }

    @Test func `access granted on a previous install triggers the backfill`() async throws {
        let (env, fake) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.refresh()
        #expect(fake.snapshot.authorizationRequestCount == 0)
        #expect(fake.snapshot.fetchedRanges.count == 3)
        #expect(sync.isBackfillComplete)
    }

    @Test func `a failed sync is reported, never recorded as successful, and retried`() async throws {
        let (env, fake) = makeEnvironment()
        let sync = try #require(env.healthSync)
        fake.update {
            $0.fetchError = HealthDataError.unavailable
            $0.fetchErrorAfter = 1 // the first 30-day chunk is written, the second fails
        }
        try await connect(sync)
        guard case .failed = sync.phase else {
            Issue.record("expected a failure, got \(sync.phase)")
            return
        }
        let repository = try #require(env.dailyMetrics)
        #expect(try repository.metrics(in: sync.window).count == 30) // rows were fetched…
        #expect(sync.lastSyncedAt == nil) // …but the sync did not succeed
        #expect(!sync.isBackfillComplete)
        #expect(try env.profiles?.setting(SettingKey.healthLastSyncedAt, as: Date.self) == nil)
        let profiles = try #require(env.profiles)
        let relaunched = HealthSyncService(source: fake, metrics: repository, settings: profiles, clock: clock.appClock)
        #expect(relaunched.lastSyncedAt == nil)

        // The next automatic refresh retries at once: no throttle after a failure.
        fake.update { $0.fetchError = nil }
        await sync.refresh()
        #expect(sync.phase == .idle)
        #expect(sync.isBackfillComplete)
        #expect(try repository.metrics(in: sync.window).count == 90)
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
        try await connect(sync)
        fake.update { $0.samples[.bodyMass] = [] }
        await sync.refresh(force: true)
        #expect(try env.dailyMetrics?.metrics(on: sync.today)?.weightKg == nil)
        #expect(try env.dailyMetrics?.metrics(on: sync.today.adding(days: -40))?.weightKg == nil)
        #expect(try env.dailyMetrics?.metrics(on: sync.today)?.steps != nil)
    }

    @Test func `the calendar is read at the start of every sync`() async throws {
        // 2026-11-09 23:30 UTC: already 2026-11-10 in Zagreb, still 2026-11-09 in New York.
        let instant = Date(timeIntervalSince1970: 1_794_267_000)
        let box = CalendarBox(timeZone: "Europe/Zagreb")
        let fake = FakeHealthDataSource()
        fake.update { $0.authorizationRequested = true }
        let db = try AppDatabase.inMemory()
        let sync = HealthSyncService(
            source: fake,
            metrics: DailyMetricsRepository(db),
            settings: ProfileRepository(db),
            clock: AppClock { instant },
            calendar: { box.calendar },
        )
        await sync.refresh(force: true)
        #expect(fake.snapshot.fetchedRanges.first?.upperBound == LocalDay("2026-11-10"))
        #expect(fake.snapshot.fetchedTimeZones.first?.identifier == "Europe/Zagreb")

        box.calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        #expect(sync.today == LocalDay("2026-11-09"))
        await sync.refresh(force: true)
        #expect(fake.snapshot.fetchedRanges.dropFirst(3).first?.upperBound == LocalDay("2026-11-09"))
        #expect(fake.snapshot.fetchedTimeZones.last?.identifier == "America/New_York")
    }

    @Test func `a time or time zone change forces a full re-sync`() async throws {
        let (env, fake) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.refresh()
        #expect(fake.snapshot.fetchedRanges.count == 3)
        await env.systemTimeDidChange() // within the throttle interval: still runs
        #expect(fake.snapshot.fetchedRanges.count == 6)
        #expect(Array(fake.snapshot.fetchedRanges.suffix(3)) == fullWindowChunks(endingOn: sync.today))
    }

    @Test func `a nap ending at 18 00 on a backfill chunk boundary is kept`() async throws {
        let today = LocalDay.today(now: clock.appClock.now())
        // The second backfill chunk ends with the night of today-30, whose window ends at 18:00 that day.
        let boundary = today.adding(days: -30)
        let end = boundary.date(atHour: 18)
        let nap = SleepSample(
            start: end.addingTimeInterval(-3600), end: end, stage: .asleepCore,
            source: FakeHealthDataSource.demoWatch,
        )
        let fake = FakeHealthDataSource()
        fake.update {
            $0.authorizationRequested = true
            $0.sleep = [nap]
        }
        let env = AppEnvironment.preview(clock: clock.appClock, health: fake)
        await env.healthSync?.refresh()
        #expect(fake.snapshot.fetchedRanges.dropFirst().first?.upperBound == boundary)
        #expect(try env.dailyMetrics?.metrics(on: boundary)?.sleepAsleepMin == 60)
        #expect(try env.dailyMetrics?.metrics(on: boundary.next)?.sleepAsleepMin == nil)
    }

    @Test func `after a reinstall, own samples with no local row are read like any other source`() async throws {
        // 2026-11-10 10:00 in Zagreb.
        let instant = Date(timeIntervalSince1970: 1_794_301_200)
        let box = CalendarBox(timeZone: "Europe/Zagreb")
        let calendar = box.calendar
        let today = LocalDay.today(calendar: calendar, now: instant)
        let at = { (day: LocalDay, hour: Int) in day.date(atHour: hour, calendar: calendar) }
        let db = try AppDatabase.inMemory()
        let appClock = AppClock { instant }
        let weights = WeightRepository(db, clock: appClock)
        let water = WaterRepository(db, clock: appClock)
        // Local rows: a weigh-in and a glass written to Health moments ago, and a weight deleted locally whose sample
        // Health still holds (its deletion is queued).
        let localWeight = try weights.add(kg: 80.0, bodyFatPct: 20, measuredAt: at(today, 7))
        let deletedWeight = try weights.add(kg: 82.0, measuredAt: at(today.adding(days: -2), 7))
        try weights.softDelete(ids: [deletedWeight.id])
        let localGlass = try water.add(ml: 300, day: today, loggedAt: at(today, 9))

        let own = HealthSource(name: "Vitalion", bundleIdentifier: "test.vitalion", productType: "iPhone17,1")
        let other = FakeHealthDataSource.demoWatch
        let fake = FakeHealthDataSource()
        fake.update {
            $0.authorizationRequested = true
            $0.samples[.bodyMass] = [
                HealthQuantitySample(start: at(today, 7), value: 80.0, source: own, externalID: localWeight.id),
                HealthQuantitySample(start: at(today.adding(days: -2), 7), value: 82.0, source: own, externalID: deletedWeight.id),
                // Written by the previous install: no local row.
                HealthQuantitySample(start: at(today.adding(days: -1), 7), value: 81.0, source: own, externalID: "old-install-weight"),
            ]
            $0.samples[.bodyFatPercentage] = [
                HealthQuantitySample(start: at(today, 7), value: 20, source: own, externalID: localWeight.id),
                HealthQuantitySample(start: at(today.adding(days: -1), 7), value: 21, source: own, externalID: "old-install-weight"),
            ]
            $0.cumulativeSamples[.dietaryWater] = [
                HealthQuantitySample(start: at(today, 9), value: 300, source: own, externalID: localGlass.id),
                HealthQuantitySample(start: at(today, 11), value: 200, source: other),
                HealthQuantitySample(start: at(today.adding(days: -1), 9), value: 500, source: own, externalID: "old-install-glass"),
            ]
        }
        let metrics = DailyMetricsRepository(db)
        let sync = HealthSyncService(
            source: fake, ownBundleIdentifier: own.bundleIdentifier, metrics: metrics, settings: ProfileRepository(db),
            clock: appClock, calendar: { box.calendar },
        )
        await sync.refresh(force: true)

        let yesterday = try #require(try metrics.metrics(on: today.adding(days: -1)))
        #expect(yesterday.weightKg == 81.0)
        #expect(yesterday.bodyFatPct == 21)
        #expect(yesterday.waterMl == 500) // no local water that day: the orphaned glass counts, once
        // Local rows are never read back: today's water from Health is the other source's 200 ml only
        // (the 300 ml glass comes from water_entry), and the weights stay with weight_entry.
        let todayRow = try #require(try metrics.metrics(on: today))
        #expect(todayRow.weightKg == nil)
        #expect(todayRow.bodyFatPct == nil)
        #expect(todayRow.waterMl == 200)
        #expect(try metrics.metrics(on: today.adding(days: -2))?.weightKg == nil) // deleted locally: not foreign data
    }
}

/// A calendar the test can change between syncs (the device moving to another time zone).
@MainActor
final class CalendarBox {
    var calendar: Calendar

    init(timeZone: String) {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
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
        await sync.waitForSync()
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
        #expect(env.healthSync?.requestStatus == .shouldRequest)
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
        #expect(LiveHealthDataSource.shareTypes.count == 10)
    }

    @Test func `sleep values map to stages`() {
        let mapped = [
            HKCategoryValueSleepAnalysis.inBed, .asleepUnspecified, .awake, .asleepCore, .asleepDeep, .asleepREM,
        ].map { SleepStage(sleepAnalysisValue: $0.rawValue) }
        #expect(mapped == [.inBed, .asleepUnspecified, .awake, .asleepCore, .asleepDeep, .asleepREM])
        #expect(SleepStage(sleepAnalysisValue: 999) == nil)
    }
}
