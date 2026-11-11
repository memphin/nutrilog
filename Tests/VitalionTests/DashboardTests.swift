import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

// MARK: - Tile state, layout, settings

struct TileStateTests {
    @Test func `a value always shows`() {
        for access in [HealthAccess.unavailable, .notRequested, .requested] {
            #expect(TileState.resolve(hasValue: true, access: access, isFirstSync: true) == .ready)
        }
        // Tiles that don't use Health are always ready.
        #expect(TileState.resolve(hasValue: false, usesHealth: false, access: .unavailable, isFirstSync: false) == .ready)
    }

    @Test func `without a value: unavailable, needs access, loading, or no data (denied looks the same)`() {
        #expect(TileState.resolve(hasValue: false, access: .unavailable, isFirstSync: false) == .unavailable)
        #expect(TileState.resolve(hasValue: false, access: .notRequested, isFirstSync: false) == .needsAccess)
        #expect(TileState.resolve(hasValue: false, access: .requested, isFirstSync: true) == .loading)
        let empty = TileState.resolve(hasValue: false, access: .requested, isFirstSync: false)
        #expect(empty == .noData(HealthKitClient.noDataMessage))
        #expect(empty.message == "No data found — check Health permissions")
        #expect(TileState.ready.message == nil)
        #expect(TileState.unavailable.message == TileState.unavailableMessage)
    }

    @Test func `access from the authorization request status`() {
        #expect(HealthAccess(isAvailable: false, status: .unnecessary, isConnected: true) == .unavailable)
        #expect(HealthAccess(isAvailable: true, status: .shouldRequest, isConnected: false) == .notRequested)
        #expect(HealthAccess(isAvailable: true, status: .unnecessary, isConnected: true) == .requested)
        #expect(HealthAccess(isAvailable: true, status: .unknown, isConnected: false) == .requested)
        #expect(HealthAccess(isAvailable: true, status: nil, isConnected: false) == .checking)
        // Connected before, and an update added types to allow: still connected.
        #expect(HealthAccess(isAvailable: true, status: .shouldRequest, isConnected: true) == .requested)
        #expect(TileState.resolve(hasValue: false, access: .checking, isFirstSync: false) == .loading)
    }

    @Test func `snapshot maps each tile to its state`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        var data = DashboardData(today: today)
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, steps: 1234), fetchedAt: Date())]
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot.state(of: .steps, access: .requested, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .sleep, access: .requested, isFirstSync: false) == .noData(HealthKitClient.noDataMessage))
        #expect(snapshot.state(of: .weight, access: .notRequested, isFirstSync: false) == .needsAccess)
        #expect(snapshot.state(of: .hrv, access: .requested, isFirstSync: true) == .loading)
        #expect(snapshot.state(of: .energy, access: .unavailable, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .water, access: .unavailable, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .totalEnergy, access: .unavailable, isFirstSync: false) == .unavailable)
    }
}

@MainActor
struct DashboardLayoutTests {
    @Test func `default shows every tile in catalog order`() {
        #expect(DashboardLayout.default.visible == DashboardTile.allCases)
        #expect(DashboardLayout.default.hidden.isEmpty)
    }

    @Test func `order and hidden tiles are persisted`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(DashboardLayout.load(from: profiles) == .default)

        var layout = DashboardLayout.default
        try layout.move(fromOffsets: [#require(DashboardTile.allCases.firstIndex(of: .weight))], toOffset: 0)
        layout.setVisible(.bodyFat, false)
        try layout.save(to: profiles)

        let loaded = DashboardLayout.load(from: profiles)
        #expect(loaded == layout)
        #expect(loaded.order.first == .weight)
        #expect(!loaded.visible.contains(.bodyFat))
        #expect(loaded.order.contains(.bodyFat)) // hidden tiles keep their place
    }

    @Test func `the dashboard follows the layout saved in Settings`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        let model = DashboardModel(environment: env)
        var layout = DashboardLayout.default
        layout.setVisible(.hrv, false)
        try layout.moveVisible(fromOffsets: [#require(layout.visible.firstIndex(of: .water))], toOffset: 0)
        try layout.save(to: profiles)
        model.reloadSettings() // Today re-reads its settings when it appears
        #expect(model.layout.hidden == [.hrv])
        #expect(model.layout.visible.first == .water)
        #expect(model.layout.order.last == .hrv) // hidden tiles follow the visible ones
    }

    @Test func `showing a hidden tile puts it last among the visible ones`() {
        var layout = DashboardLayout.default
        layout.setVisible(.water, false)
        layout.setVisible(.hrv, false)
        layout.show(.water)
        #expect(layout.visible.last == .water)
        #expect(layout.hidden == [.hrv])
        #expect(layout.order.last == .hrv)
        #expect(Set(layout.order) == Set(DashboardTile.allCases))
        layout.show(.steps) // already visible: nothing changes
        #expect(layout.visible.last == .water)
    }

    @Test func `unknown and duplicate tiles are dropped, missing ones added`() throws {
        let json = #"{"order":["water","future-tile","water","steps"],"hidden":["steps","other"]}"#
        let layout = try JSONDecoder().decode(DashboardLayout.self, from: Data(json.utf8))
        // Missing tiles follow the tile before them in the default order; `energy` has none and goes last.
        #expect(layout.order == [.water, .caffeine, .sleep, .weight, .bodyFat, .steps, .totalEnergy, .restingHeartRate, .hrv, .energy])
        #expect(Set(layout.order) == Set(DashboardTile.allCases))
        #expect(layout.order.count == DashboardTile.allCases.count)
        #expect(layout.hidden == [.steps])
        // Round trip.
        let again = try JSONDecoder().decode(DashboardLayout.self, from: JSONEncoder().encode(layout))
        #expect(again == layout)
    }

    @Test func `a saved layout with the old active energy tile loads without it`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        // Active energy was merged into Total energy (#66): a layout saved before still loads, in the user's order.
        let saved = #"{"order":["weight","energy","water","sleep","bodyFat","steps","activeEnergy","totalEnergy","restingHeartRate","hrv"],"#
            + #""hidden":["hrv","activeEnergy"]}"#
        try profiles.setSetting(SettingKey.dashboardLayout, JSONDecoder().decode(OldLayout.self, from: Data(saved.utf8)))
        let layout = DashboardLayout.load(from: profiles)
        #expect(layout.order == [.weight, .energy, .water, .caffeine, .sleep, .bodyFat, .steps, .totalEnergy, .restingHeartRate, .hrv])
        #expect(layout.hidden == [.hrv])
        // A layout from before Total energy existed gets it after Steps, visible.
        let older = #"{"order":["steps","activeEnergy","energy"],"hidden":[]}"#
        let olderLayout = try JSONDecoder().decode(DashboardLayout.self, from: Data(older.utf8))
        #expect(Array(olderLayout.order.prefix(2)) == [.steps, .totalEnergy])
        #expect(olderLayout.visible.contains(.totalEnergy))
    }

    /// The setting exactly as an older version stored it (raw strings).
    private struct OldLayout: Codable, Sendable {
        var order: [String]
        var hidden: [String]
    }

    @Test func `rows pair narrow tiles and give wide tiles a row`() {
        let layout = DashboardLayout(
            order: [.energy, .steps, .weight, .bodyFat, .water, .sleep, .hrv, .restingHeartRate, .totalEnergy], hidden: [],
        )
        #expect(layout.rows == [
            [.energy],
            [.steps, .weight],
            [.bodyFat],
            [.water],
            [.caffeine], // not in the order given: added after water, a wide tile
            [.sleep, .hrv], // sleep shows one number now (#62), so it pairs up
            [.restingHeartRate, .totalEnergy],
        ])
        var hidden = layout
        hidden.setVisible(.weight, false)
        #expect(hidden.rows.prefix(3) == [[.energy], [.steps, .bodyFat], [.water]])
    }
}

@MainActor
struct WaterQuickAddTests {
    @Test func `sizes default to 250 and 500 and are normalized`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(WaterQuickAdd.sizes(from: profiles) == [250, 500])
        #expect(try WaterQuickAdd.save([500, 330, 200, 330, 10, 5000, 750, 1000], to: profiles) == [200, 330, 500, 750])
        #expect(WaterQuickAdd.sizes(from: profiles) == [200, 330, 500, 750])
        #expect(WaterQuickAdd.normalized([]) == [250, 500])
        #expect(WaterQuickAdd.normalized([1]) == [250, 500])
    }

    @Test func `add size picks a free value or none`() {
        #expect(WaterQuickAdd.nextSize(after: [250, 500]) == 750)
        #expect(WaterQuickAdd.nextSize(after: [1750, 2000]) == 50) // the capped 2000 is taken: first free step
        #expect(WaterQuickAdd.nextSize(after: [250, 500, 750, 1000]) == nil) // full
    }

    @Test func `goal progress includes other apps' water`() {
        let half = WaterProgress(loggedMl: 500, otherAppsMl: 750, goalMl: 2500)
        #expect(half.totalMl == 1250)
        #expect(half.fraction == 0.5)
        #expect(!half.isGoalReached)
        #expect(half.remainingMl == 1250)
        let over = WaterProgress(loggedMl: 2000, otherAppsMl: 1000, goalMl: 2500)
        #expect(over.fraction == 1)
        #expect(over.isGoalReached)
        #expect(over.remainingMl == 0)
        #expect(WaterProgress(loggedMl: 100, otherAppsMl: 0, goalMl: 0).fraction == 0)
    }
}

// MARK: - Model with fakes

@MainActor
struct DashboardModelTests {
    let clock = ManualClock()
    let source: FakeHealthDataSource
    let writer: FakeHealthWriter
    let env: AppEnvironment

    init() {
        source = FakeHealthDataSource()
        source.update { $0.authorizationRequested = true }
        writer = FakeHealthWriter(mirror: source)
        env = AppEnvironment.preview(clock: clock.appClock, health: source, healthWriter: writer)
    }

    var today: LocalDay {
        env.today
    }

    var links: HealthKitLinkRepository {
        HealthKitLinkRepository(env.db!, clock: clock.appClock)
    }

    func values(_ id: String) -> [HealthWriteType: Double] {
        Dictionary(uniqueKeysWithValues: writer.snapshot.samples(for: id).map { ($0.type, $0.value) })
    }

    @Test func `water quick-add adds to today's total, undo removes it`() async throws {
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        model.addWater(ml: 250)
        model.addWater(ml: 500)
        #expect(await waitUntil { model.snapshot.water.loggedMl == 750 })
        #expect(model.undo.current?.message == "Added 500 ml water")
        #expect(try env.water?.totalMl(for: today) == 750)

        model.undo.performUndo()
        #expect(await waitUntil { model.snapshot.water.loggedMl == 250 })
        #expect(try env.water?.totalMl(for: today) == 250)

        // Deleting from the detail list offers restore.
        let entry = try #require(model.data.water.first)
        model.deleteWater([entry])
        #expect(await waitUntil { model.snapshot.water.loggedMl == 0 })
        model.undo.performUndo()
        #expect(await waitUntil { model.snapshot.water.loggedMl == 250 })
    }

    @Test func `quick-add water is written as dietaryWater and not counted twice`() async throws {
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        // Another app logged 300 ml today.
        let other = HealthSource(name: "WaterMinder", bundleIdentifier: "com.waterminder")
        source.update {
            $0.cumulativeSamples[.dietaryWater] = [HealthQuantitySample(start: today.date(atHour: 9), value: 300, source: other)]
        }
        model.addWater(ml: 500)
        await env.refreshHealth() // writes the queued entry, then re-reads Health (which now holds our 500 ml too)
        let entry = try #require(try env.water?.entries(for: today).first)
        #expect(values(entry.id) == [.dietaryWater: 500])
        #expect(await waitUntil { model.snapshot.water.otherAppsMl == 300 })
        #expect(model.snapshot.water.totalMl == 800)
    }

    @Test func `saving a weight writes body mass and body fat through the outbox`() async throws {
        let model = DashboardModel(environment: env)
        let measured = clock.appClock.now().addingTimeInterval(-3600)
        #expect(model.saveWeight(kg: 81.3, bodyFatPct: 18.4, measuredAt: measured))
        let entry = try #require(try env.weights?.latest())
        #expect(try links.pending().map(\.ownerID) == [entry.id]) // queued in the same transaction

        await env.healthWrites?.drain()
        #expect(values(entry.id) == [.bodyMass: 81.3, .bodyFatPercentage: 18.4])
        let drafts = writer.snapshot.samples(for: entry.id)
        #expect(drafts.allSatisfy { $0.date == measured && $0.version == 1001 })
        #expect(try Set(links.links(for: .weightEntry, id: entry.id).map(\.hkType))
            == [HealthWriteType.bodyMass.identifier, HealthWriteType.bodyFatPercentage.identifier])
        #expect(try links.pending().isEmpty)
    }

    @Test func `editing a weight rewrites its samples, deleting removes them, undo writes them again`() async throws {
        let model = DashboardModel(environment: env)
        model.saveWeight(kg: 82, bodyFatPct: 19, measuredAt: clock.appClock.now())
        await env.healthWrites?.drain()
        let entry = try #require(try env.weights?.latest())
        let firstUUIDs = try Set(links.links(for: .weightEntry, id: entry.id).map(\.hkUUID))

        // Edit: drop body fat, change kg.
        #expect(model.saveWeight(kg: 81.5, bodyFatPct: nil, measuredAt: entry.measuredAt, editing: entry))
        await env.healthWrites?.drain()
        #expect(values(entry.id) == [.bodyMass: 81.5])
        #expect(writer.snapshot.samples(for: entry.id).allSatisfy { $0.version == 2001 })
        #expect(writer.snapshot.deleteCalls.last?.externalID == entry.id)
        let newUUIDs = try Set(links.links(for: .weightEntry, id: entry.id).map(\.hkUUID))
        #expect(newUUIDs.count == 1)
        #expect(newUUIDs.isDisjoint(with: firstUUIDs))

        // Delete, then undo.
        let edited = try #require(try env.weights?.entry(id: entry.id))
        model.deleteWeight(edited)
        await env.healthWrites?.drain()
        #expect(values(entry.id).isEmpty)
        #expect(try links.links(for: .weightEntry, id: entry.id).isEmpty)
        model.undo.performUndo()
        await env.healthWrites?.drain()
        #expect(values(entry.id) == [.bodyMass: 81.5])
    }

    @Test func `with writing off, weights stay in Vitalion`() async throws {
        let model = DashboardModel(environment: env)
        try env.healthWrites?.setEnabled(false)
        model.saveWeight(kg: 80, bodyFatPct: nil, measuredAt: clock.appClock.now())
        await env.healthWrites?.drain()
        #expect(writer.snapshot.saveCalls.isEmpty)
        #expect(try env.weights?.latest()?.kg == 80)
    }

    @Test func `weight permission denied: the row is done, nothing written`() async throws {
        writer.update {
            $0.authorization[.bodyMass] = .denied
            $0.authorization[.bodyFatPercentage] = .denied
        }
        let model = DashboardModel(environment: env)
        model.saveWeight(kg: 80, bodyFatPct: 20, measuredAt: clock.appClock.now())
        await env.healthWrites?.drain()
        #expect(writer.snapshot.saveCalls.isEmpty)
        #expect(try links.pending().isEmpty)
    }

    @Test func `invalid weights are rejected with a message`() {
        let model = DashboardModel(environment: env)
        #expect(!model.saveWeight(kg: 0, bodyFatPct: nil, measuredAt: clock.appClock.now()))
        #expect(model.errorMessage != nil)
    }

    @Test func `a manual weight shows immediately and is not counted twice once Health returns it`() async throws {
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        model.saveWeight(kg: 79.4, bodyFatPct: 17.5, measuredAt: today.date(atHour: 7))
        // Immediately, before any Health write or read.
        #expect(await waitUntil { model.snapshot.weight?.latestKg == 79.4 })
        #expect(model.snapshot.bodyFat?.pct == 17.5)
        #expect(model.snapshot.weight?.latest.isManual == true)

        // Written to Health, read back: our own sample is ignored, so daily_metrics has no weight for today.
        await env.refreshHealth()
        #expect(source.snapshot.samples[.bodyMass]?.map(\.value) == [79.4])
        #expect(try env.dailyMetrics?.metrics(on: today)?.weightKg == nil)
        #expect(model.snapshot.dayWeights.filter { $0.day == today }.count == 1)
        #expect(model.snapshot.weight?.latestKg == 79.4)
        #expect(model.snapshot.weight?.trendKg == 79.4)

        // A scale weigh-in on the same day: the manual entry still wins for that day.
        let scale = HealthSource(name: "Withings", bundleIdentifier: "com.withings.wiScaleNG")
        source.update {
            $0.samples[.bodyMass, default: []].append(HealthQuantitySample(start: today.date(atHour: 6), value: 80.1, source: scale))
        }
        await env.refreshHealth()
        #expect(try env.dailyMetrics?.metrics(on: today)?.weightKg == 80.1)
        #expect(await waitUntil { model.data.metrics.contains { $0.day == today && $0.weightKg == 80.1 } })
        #expect(model.snapshot.weight?.latestKg == 79.4)
        #expect(model.snapshot.dayWeights.count == 1)

        // Deleting the manual entry falls back to the scale.
        let entry = try #require(try env.weights?.latest())
        model.deleteWeight(entry)
        #expect(await waitUntil { model.snapshot.weight?.latestKg == 80.1 })
        #expect(model.snapshot.weight?.latest.isManual == false)
    }

    @Test func `detail lists the last 14 days, newest first`() async throws {
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        model.addWater(ml: 330)
        try env.water?.add(ml: 250, day: today.adding(days: -2))
        #expect(await waitUntil { model.snapshot.water.loggedMl == 330 })
        let rows = model.history(for: .water)
        #expect(rows.count == TileHistory.days)
        #expect(rows.first?.day == today)
        #expect(rows.last?.day == today.adding(days: -13))
        #expect(rows[0].value == DashboardFormat.ml(330))
        #expect(rows[1].value == nil)
        #expect(rows[2].value == DashboardFormat.ml(250))
    }
}

// MARK: - Demo data (the §1.3 exit criterion with -uiSampleData)

@MainActor
struct DashboardDemoTests {
    @Test func `every tile is populated from Health with no manual input`() async throws {
        let env = AppEnvironment.preview(sampleData: true)
        await env.healthSync?.refresh()
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        // The diary totals come from their own observation, after the tiles: wait for them too.
        #expect(await waitUntil(timeout: .seconds(5)) {
            DashboardTile.allCases.allSatisfy { model.state(of: $0) == .ready } && model.snapshot.water.otherAppsMl > 0
                && model.snapshot.totals.kcal > 0
        })
        let snapshot = model.snapshot
        #expect(model.access == .requested)
        #expect(snapshot.steps != nil)
        #expect(snapshot.sleep?.hasStages == true)
        #expect(snapshot.weight?.trendChange7d != nil)
        #expect(snapshot.bodyFat != nil)
        #expect(snapshot.hrv?.deviationText != nil)
        #expect(snapshot.restingHR != nil)
        #expect(snapshot.energyBurned?.totalKcal != nil)
        // A week of demo history: every tile but calories and caffeine (whose tile draws today's curve) has a
        // sparkline and a spoken trend.
        for tile in DashboardTile.allCases where tile != .energy && tile != .caffeine {
            #expect(snapshot.sparkline(for: tile) != nil, "\(tile)")
            #expect(snapshot.accessibilityTrend(of: tile, state: .ready) != nil, "\(tile)")
        }
        #expect(snapshot.sparkline(for: .energy) == nil)
        #expect(snapshot.totals.kcal > 0)
        #expect(try env.weights?.latest() == nil) // nothing entered by hand
    }

    @Test func `before Health is connected, Health tiles ask for access`() async {
        let env = AppEnvironment.preview() // fake Health, never asked
        let model = DashboardModel(environment: env)
        await model.reloadAccess()
        #expect(model.access == .notRequested)
        #expect(model.state(of: .steps) == .needsAccess)
        #expect(model.state(of: .energy) == .ready)
        #expect(model.state(of: .water) == .ready)
    }
}

// MARK: - Weight form

struct WeightFormTests {
    @Test func `parses kg and optional body fat`() {
        var form = WeightForm(measuredAt: Date())
        #expect(!form.isValid)
        form.kg = "81,4"
        #expect(form.kgValue == 81.4)
        #expect(form.isValid)
        #expect(form.bodyFatInput == .empty)
        form.bodyFat = "18.5"
        #expect(form.bodyFatValue == 18.5)
        form.bodyFat = "95"
        #expect(form.bodyFatInput == .invalid)
        #expect(!form.isValid)
        form.bodyFat = " "
        #expect(form.isValid)
        form.kg = "0"
        #expect(!form.isValid)
    }
}

struct DashboardFormatTests {
    @Test func `durations and changes`() {
        #expect(DashboardFormat.duration(440) == "7h 20min")
        #expect(DashboardFormat.duration(65) == "1h 5min")
        #expect(DashboardFormat.duration(45) == "45min")
        #expect(DashboardFormat.kgChange(-0.44).hasPrefix("−"))
        #expect(DashboardFormat.kgChange(0.21).hasPrefix("+"))
        #expect(DashboardFormat.kgChange(0.01).hasPrefix("±"))
    }
}
