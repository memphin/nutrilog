import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

/// Health access on the dashboard: connect from anywhere, new types after an update (PR #57 review).
@MainActor
struct DashboardAccessTests {
    @Test func `connecting moves the tiles from Connect to loading to no data`() async throws {
        let source = FakeHealthDataSource() // empty, never asked
        let gate = SaveGate()
        source.update { $0.beforeFetch = { await gate.pass() } }
        let env = AppEnvironment.preview(health: source)
        let model = DashboardModel(environment: env)
        await model.reloadAccess()
        #expect(model.state(of: .steps) == .needsAccess)

        // Connect through the environment (onboarding / Settings), not through the dashboard.
        let connecting = Task { try await env.connectHealth() }
        #expect(await waitUntil { model.state(of: .steps) == .loading })
        #expect(model.access == .requested)
        gate.open()
        try await connecting.value
        await env.healthSync?.waitForSync()
        #expect(await waitUntil { model.state(of: .steps) == .noData(HealthKitClient.noDataMessage) })
        #expect(model.state(of: .weight) == .noData(HealthKitClient.noDataMessage))
    }

    @Test func `new types after an update don't turn the tiles back into Connect`() async throws {
        let source = FakeHealthDataSource()
        source.update { $0.authorizationRequested = true }
        let env = AppEnvironment.preview(health: source)
        let sync = try #require(env.healthSync)
        await sync.refresh(force: true)
        #expect(sync.isBackfillComplete)

        source.update { $0.authorizationRequested = false } // an app update added a type: Health asks again
        let model = DashboardModel(environment: env)
        await model.reloadAccess()
        #expect(sync.requestStatus == .shouldRequest)
        #expect(sync.hasNewTypesToAllow)
        #expect(sync.isConnected)
        #expect(model.access == .requested)
        #expect(model.state(of: .steps) == .noData(HealthKitClient.noDataMessage))
    }
}

/// Weight rows when only part of the weight types may be written (body fat was added after users connected).
@MainActor
struct WeightWritePermissionTests {
    let clock = ManualClock()
    let source = FakeHealthDataSource()
    let writer: FakeHealthWriter
    let env: AppEnvironment

    init() {
        source.update { $0.authorizationRequested = true }
        writer = FakeHealthWriter(mirror: source)
        env = AppEnvironment.preview(clock: clock.appClock, health: source, healthWriter: writer)
    }

    var links: HealthKitLinkRepository {
        HealthKitLinkRepository(env.db!, clock: clock.appClock)
    }

    func values(_ id: String) -> [HealthWriteType: Double] {
        Dictionary(uniqueKeysWithValues: writer.snapshot.samples(for: id).map { ($0.type, $0.value) })
    }

    @Test func `body mass allowed, body fat not asked: mass is written, fat follows once allowed`() async throws {
        writer.update { $0.authorization[.bodyFatPercentage] = .notDetermined }
        #expect(await env.shouldOfferBodyFatWriting())
        let weights = try #require(env.weights)
        let withFat = try weights.add(kg: 80, bodyFatPct: 18)
        let withoutFat = try weights.add(kg: 79)
        await env.healthWrites?.drain()
        #expect(values(withFat.id) == [.bodyMass: 80])
        #expect(values(withoutFat.id) == [.bodyMass: 79])
        #expect(try links.pending().isEmpty) // not held back for body fat

        // "Allow body fat writing" → granted: recent weights with body fat get their body fat sample.
        writer.update { $0.authorization[.bodyFatPercentage] = nil }
        let saves = writer.snapshot.saveCalls.count
        try await env.allowBodyFatWriting()
        #expect(values(withFat.id) == [.bodyMass: 80, .bodyFatPercentage: 18])
        #expect(writer.snapshot.saveCalls.count == saves + 1) // the weight without body fat was not rewritten
        #expect(try links.links(for: .weightEntry, id: withFat.id).count == 2)
        #expect(await env.shouldOfferBodyFatWriting() == false)
    }

    @Test func `body mass denied, body fat not asked: the row is done, not queued forever`() async throws {
        writer.update {
            $0.authorization[.bodyMass] = .denied
            $0.authorization[.bodyFatPercentage] = .notDetermined
        }
        try #require(env.weights).add(kg: 80, bodyFatPct: 18)
        await env.healthWrites?.drain()
        #expect(writer.snapshot.saveCalls.isEmpty)
        #expect(try links.pending().isEmpty)
    }

    @Test func `body mass not asked: the row waits`() async throws {
        writer.update {
            $0.authorization[.bodyMass] = .notDetermined
            $0.authorization[.bodyFatPercentage] = .notDetermined
        }
        let entry = try #require(env.weights).add(kg: 80)
        await env.healthWrites?.drain()
        #expect(try links.pending().map(\.ownerID) == [entry.id])
        #expect(await env.shouldOfferBodyFatWriting() == false) // the regular onboarding asks for both
    }

    @Test func `the body fat offer can be dismissed for good`() async {
        writer.update { $0.authorization[.bodyFatPercentage] = .notDetermined }
        #expect(await env.shouldOfferBodyFatWriting())
        env.dismissBodyFatWritingOffer()
        #expect(await env.shouldOfferBodyFatWriting() == false)
    }

    @Test func `today's manual weigh-in is the one entered last`() async throws {
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        let today = env.today
        model.saveWeight(kg: 81, bodyFatPct: nil, measuredAt: today.date(atHour: 7))
        clock.advance(hours: 1)
        model.saveWeight(kg: 80.6, bodyFatPct: nil, measuredAt: today.date(atHour: 6))
        #expect(await waitUntil { model.data.manualWeights.count == 2 })
        #expect(model.todaysManualWeight?.kg == 80.6)
        #expect(model.snapshot.weight?.latestKg == 80.6)
    }
}

struct DashboardAccessibilityTests {
    let today = LocalDay("2026-11-30")!

    @Test func `weight reads as one sentence`() {
        var data = DashboardData(today: today)
        for offset in (0 ..< 10).reversed() {
            let day = today.adding(days: -offset)
            data.metrics.append(DailyMetricsRecord(DailyHealthMetrics(day: day, weightKg: 80 + Double(offset) / 10), fetchedAt: Date()))
        }
        let label = DashboardSnapshot(data).accessibilityLabel(of: .weight, state: .ready)
        // Like the tile: the weight only (#73).
        #expect(label == "Weight, 80.0 kilograms, below the weekly average")
    }

    @Test func `tiles without data say no data and why`() {
        let snapshot = DashboardSnapshot(DashboardData(today: today))
        #expect(snapshot.accessibilityLabel(of: .steps, state: .noData(HealthKitClient.noDataMessage))
            == "Steps, no data. No data found — check Health permissions")
        #expect(snapshot.accessibilityLabel(of: .sleep, state: .needsAccess) == "Sleep, no data. \(TileState.needsAccessMessage)")
        // At 08:00, an hour after the 07:00 wake-up, nothing drunk is still on pace.
        #expect(snapshot.accessibilityLabel(of: .water, state: .ready, now: today.date(atHour: 8))
            == "Hydration, 0 of 2,500 millilitres, on pace")
        #expect(snapshot.accessibilityLabel(of: .energy, state: .ready).hasPrefix("Calories, 0 calories eaten"))
        #expect(DashboardSnapshot.spokenDuration(425) == "7 hours 5 minutes")
        #expect(DashboardSnapshot.spokenDuration(60) == "1 hour")
        #expect(DashboardSnapshot.spokenDuration(45) == "45 minutes")
    }
}
