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
        let snapshot = dashboardSnapshot(today: today, metrics: [DailyHealthMetrics(day: today, steps: 1234)])
        #expect(snapshot.state(of: .steps, access: .requested, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .sleep, access: .requested, isFirstSync: false) == .noData(HealthKitClient.noDataMessage))
        #expect(snapshot.state(of: .weight, access: .notRequested, isFirstSync: false) == .needsAccess)
        #expect(snapshot.state(of: .hrv, access: .requested, isFirstSync: true) == .loading)
        #expect(snapshot.state(of: .energy, access: .unavailable, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .water, access: .unavailable, isFirstSync: false) == .ready)
        #expect(snapshot.state(of: .totalEnergy, access: .unavailable, isFirstSync: false) == .unavailable)
    }

    @Test func `the previous days draw with a value and with none yet today, not without access`() {
        #expect(TileState.ready.showsHistory)
        #expect(TileState.noData(HealthKitClient.noDataMessage).showsHistory)
        #expect(!TileState.loading.showsHistory)
        #expect(!TileState.needsAccess.showsHistory)
        #expect(!TileState.unavailable.showsHistory)
    }

    @Test func `first thing in the morning the tiles still chart the previous days`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        // Steps, sleep and total energy on the six days before; nothing yet today.
        let metrics = (1 ... 6).map { offset in
            DailyHealthMetrics(
                day: today.adding(days: -offset), steps: 8000 + offset * 100, activeKcal: 400, basalKcal: 1600,
                sleepAsleepMin: 420,
            )
        }
        let snapshot = dashboardSnapshot(today: today, metrics: metrics)
        for tile in [DashboardTile.steps, .sleep, .totalEnergy] {
            let state = snapshot.state(of: tile, access: .requested, isFirstSync: false)
            #expect(state == .noData(HealthKitClient.noDataMessage), "\(tile)")
            #expect(snapshot.sparkline(for: tile) != nil, "\(tile)")
            #expect(snapshot.accessibilityTrend(of: tile, state: state) != nil, "\(tile)")
        }
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
        #expect(layout.order == [.water, .caffeine, .sleep, .weight, .bodyFat, .steps, .totalEnergy, .restingHeartRate, .hrv, .weeklyReport, .energy])
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
        // Active energy was merged into Total energy, the one energy-burned tile and chart: a layout saved before
        // still loads, in the user's order.
        #expect(DashboardTile.allCases.map(\.title).count { $0.localizedCaseInsensitiveContains("energy") } == 1)
        #expect(!ChartMetric.allCases.contains { $0.rawValue == "activeEnergy" })
        #expect(ChartMetric(tile: .totalEnergy) == .totalEnergy)
        let saved = #"{"order":["weight","energy","water","sleep","bodyFat","steps","activeEnergy","totalEnergy","restingHeartRate","hrv"],"#
            + #""hidden":["hrv","activeEnergy"]}"#
        try profiles.setSetting(SettingKey.dashboardLayout, JSONDecoder().decode(OldLayout.self, from: Data(saved.utf8)))
        let layout = DashboardLayout.load(from: profiles)
        #expect(layout.order == [.weight, .energy, .water, .caffeine, .sleep, .bodyFat, .steps, .totalEnergy, .restingHeartRate, .hrv, .weeklyReport])
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

    @Test func `this week's tile reads the current week and opens the report`() throws {
        let env = AppEnvironment.preview(sampleData: true)
        let model = DashboardModel(environment: env)
        let thisWeek = env.today.weekStart(firstWeekday: Calendar.current.firstWeekday)
        #expect(model.thisWeekStart == thisWeek)
        #expect(model.thisWeek == nil)
        model.reloadThisWeek()
        let report = try #require(model.thisWeek)
        #expect(report.start == model.thisWeekStart)
        #expect(!DashboardTile.weeklyReport.usesHealth)
        #expect(model.state(of: .weeklyReport) == .ready)
        let spoken = ThisWeekTileText.spoken(report, unit: .kcal)
        #expect(spoken.hasPrefix(DashboardTile.weeklyReport.title + ", "))
        #expect(ThisWeekTileText.spoken(nil, unit: .kcal) == DashboardTile.weeklyReport.title)
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
            [.sleep, .hrv], // sleep shows one number now, so it pairs up
            [.weeklyReport, .restingHeartRate], // not in the order given: added after HRV
            [.totalEnergy],
        ])
        var hidden = layout
        hidden.setVisible(.weight, false)
        #expect(hidden.rows.prefix(3) == [[.energy], [.steps, .bodyFat], [.water]])
    }

    @Test func `dragging a tile onto another takes that tile's place`() {
        var layout = DashboardLayout.default
        layout.setVisible(.water, false)
        // Forward: lands after the target. The hidden tile (water) stays behind the visible ones.
        layout.move(.energy, onto: .sleep)
        #expect(layout.visible.prefix(4) == [.caffeine, .sleep, .energy, .weight])
        // Backward: lands before the target.
        layout.move(.hrv, onto: .caffeine)
        #expect(layout.visible.prefix(4) == [.hrv, .caffeine, .sleep, .energy])
        #expect(layout.hidden == [.water])
        #expect(layout.order.last == .water)
        #expect(Set(layout.order) == Set(DashboardTile.allCases))
        // Onto itself, onto a hidden tile, or a hidden tile: nothing changes.
        let before = layout
        layout.move(.steps, onto: .steps)
        layout.move(.steps, onto: .water)
        layout.move(.water, onto: .steps)
        #expect(layout == before)
    }

    @Test func `moving a tile by one step stops at the ends`() throws {
        var layout = DashboardLayout.default
        layout.move(.water, by: -1)
        #expect(layout.visible.prefix(3) == [.water, .energy, .caffeine])
        layout.move(.water, by: -1) // already first
        #expect(layout.visible.prefix(3) == [.water, .energy, .caffeine])
        layout.move(.energy, by: 1)
        #expect(layout.visible.prefix(3) == [.water, .caffeine, .energy])
        let last = try #require(layout.visible.last)
        let before = layout
        layout.move(last, by: 1)
        #expect(layout == before)
    }

    @Test func `editing on Today saves the layout`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        let model = DashboardModel(environment: env)
        model.moveTile(.weight, onto: .energy)
        model.hideTile(.hrv)
        #expect(model.layout.visible.first == .weight)
        #expect(model.layout.hidden == [.hrv])
        #expect(DashboardLayout.load(from: profiles) == model.layout)
        model.showTile(.hrv)
        model.moveTile(.weight, by: 1)
        #expect(model.layout.hidden.isEmpty)
        #expect(model.layout.visible.last == .hrv)
        #expect(model.layout.visible.prefix(2) == [.energy, .weight])
        #expect(DashboardLayout.load(from: profiles) == model.layout)
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

    @Test func `stepping skips over other sizes instead of merging`() {
        #expect(WaterQuickAdd.stepped(250, by: 50, among: [500]) == 300)
        #expect(WaterQuickAdd.stepped(450, by: 50, among: [500]) == 550) // skips the neighbour
        #expect(WaterQuickAdd.stepped(550, by: -50, among: [500]) == 450)
        #expect(WaterQuickAdd.stepped(450, by: 50, among: [500, 550, 600]) == 650) // skips a run of sizes
        #expect(WaterQuickAdd.stepped(300, by: -50, among: [250]) == 200)
    }

    @Test func `stepping stays put at the range ends`() {
        #expect(WaterQuickAdd.stepped(2000, by: 50, among: [250]) == 2000)
        #expect(WaterQuickAdd.stepped(50, by: -50, among: [250]) == 50)
        #expect(WaterQuickAdd.stepped(1950, by: 50, among: [2000]) == 1950) // the only step up is taken
        #expect(WaterQuickAdd.stepped(100, by: -50, among: [50]) == 100)
        #expect(WaterQuickAdd.stepped(500, by: 0, among: []) == 500)
        #expect(WaterQuickAdd.stepped(Int.max, by: 50, among: []) == Int.max) // outside the range: no overflow
    }

    @Test func `goal progress includes other apps' water`() {
        let half = WaterProgress(loggedMl: 500, otherAppsMl: 750, goalMl: 2500)
        #expect(half.totalMl == 1250)
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
        let entry = try #require(model.data.hydrationIntakes[today]?.first { $0.source == .water })
        model.deleteIntake(entry)
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
    }

    @Test func `weigh-ins older than the history window can still be listed, edited, deleted and restored`() async throws {
        let model = DashboardModel(environment: env)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        let now = clock.appClock.now()
        #expect(model.saveWeight(kg: 84, bodyFatPct: nil, measuredAt: now.addingTimeInterval(-86400 * 90)))
        #expect(model.saveWeight(kg: 80, bodyFatPct: nil, measuredAt: now.addingTimeInterval(-3600)))
        #expect(await waitUntil { model.data.manualWeights.map(\.kg) == [80] }) // the window leaves the old one out
        #expect(model.allManualWeights == nil) // not loaded until the list is opened

        let listing = Task { await model.observeAllWeights() }
        defer { listing.cancel() }
        #expect(await waitUntil { model.allManualWeights?.map(\.kg) == [80, 84] }) // newest first
        let old = try #require(model.allManualWeights?.last)

        #expect(model.saveWeight(kg: 83.5, bodyFatPct: nil, measuredAt: old.measuredAt, editing: old))
        #expect(await waitUntil { model.allManualWeights?.map(\.kg) == [80, 83.5] })
        let edited = try #require(try env.weights?.entry(id: old.id))
        model.deleteWeight(edited)
        #expect(await waitUntil { model.allManualWeights?.map(\.kg) == [80] })
        model.undo.performUndo()
        #expect(await waitUntil { model.allManualWeights?.map(\.kg) == [80, 83.5] })
        #expect(model.data.manualWeights.map(\.kg) == [80])
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
        #expect(rows[0].value == Format.ml(330))
        #expect(rows[1].value == nil)
        #expect(rows[2].value == Format.ml(250))
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
        #expect(snapshot.sleep?.asleepMin != nil)
        #expect(snapshot.weight?.trendChange7d != nil)
        #expect(snapshot.bodyFat != nil)
        #expect(snapshot.hrv?.deviationText != nil)
        #expect(snapshot.restingHR != nil)
        #expect(snapshot.energyBurned?.totalKcal != nil)
        // A week of demo history: every tile but calories, caffeine (whose tile draws today's curve) and this week
        // has a sparkline and a spoken trend.
        for tile in DashboardTile.allCases where ![.energy, .caffeine, .weeklyReport].contains(tile) {
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
        #expect(Format.duration(minutes: 440) == "7 h 20 min")
        #expect(Format.duration(minutes: 65) == "1 h 5 min")
        #expect(Format.duration(minutes: 45) == "45 min")
        #expect(Format.kgChange(-0.44).hasPrefix("−"))
        #expect(Format.kgChange(0.21).hasPrefix("+"))
        #expect(Format.kgChange(0.01).hasPrefix("±"))
    }
}

// MARK: - Sparklines

struct SparklineTests {
    let today = LocalDay("2026-11-09")!

    func days(_ values: [Int: Double]) -> [LocalDay: Double] {
        Dictionary(uniqueKeysWithValues: values.map { (today.adding(days: -$0.key), $0.value) })
    }

    @Test func `uses the seven days ending today, oldest first, and leaves gaps`() {
        // 7 days ago is outside the window; 2 and 4 days ago have no value.
        let sparkline = Sparkline(days([7: 999, 6: 1, 5: 2, 3: 4, 1: 6, 0: 7]), today: today, mark: .bar)
        #expect(sparkline.points.map(\.index) == [0, 1, 3, 5, 6])
        #expect(sparkline.points.map(\.value) == [1, 2, 4, 6, 7])
        #expect(sparkline.points.first?.day == today.adding(days: -6))
        #expect(sparkline.points.last?.day == today)
        #expect(sparkline.isDrawable)
        #expect(sparkline.direction == .up)
        #expect(sparkline.accessibilitySummary == "up over 7 days")
    }

    @Test func `no data or a single day draws nothing and says nothing`() {
        let empty = Sparkline([:], today: today, mark: .line)
        #expect(empty.points.isEmpty)
        #expect(!empty.isDrawable)
        #expect(empty.direction == nil)
        #expect(empty.accessibilitySummary == nil)
        let single = Sparkline(days([0: 80]), today: today, mark: .line)
        #expect(!single.isDrawable)
        #expect(single.accessibilitySummary == nil)
        // A future day is not part of the window.
        #expect(Sparkline([today.next: 1, today: 2], today: today, mark: .bar).points.count == 1)
    }

    @Test func `direction compares the slope with the average`() {
        #expect(Sparkline(days([6: 82.0, 3: 81.5, 0: 81.0]), today: today, mark: .line).direction == .down)
        #expect(Sparkline(days([6: 60, 5: 61, 4: 59, 3: 60, 2: 59, 1: 61, 0: 60]), today: today, mark: .line).direction == .steady)
        #expect(Sparkline(days([2: 0, 1: 0, 0: 0]), today: today, mark: .bar).direction == .steady)
        #expect(Sparkline(days([2: 0, 1: 5, 0: 0]), today: today, mark: .bar).accessibilitySummary == "up over 7 days")
    }

    @Test func `bar trends skip today's unfinished day, line trends include it`() {
        // 8 a.m.: a steady week of steps and 500 so far today.
        let morning = Sparkline(days([6: 8000, 5: 8100, 4: 7900, 3: 8000, 2: 8100, 1: 7900, 0: 500]), today: today, mark: .bar)
        #expect(morning.isDrawable)
        #expect(morning.points.count == 7) // today is still drawn
        #expect(morning.trendPoints.count == 6)
        #expect(morning.direction == .steady)
        #expect(morning.accessibilitySummary == "steady over 7 days")
        // Only yesterday complete: no trend to speak, the chart still shows.
        let short = Sparkline(days([1: 8000, 0: 500]), today: today, mark: .bar)
        #expect(short.isDrawable)
        #expect(short.direction == nil)
        // A level measured today counts.
        let weight = Sparkline(days([2: 81.0, 1: 81.0, 0: 80.0]), today: today, mark: .line)
        #expect(weight.trendPoints.count == 3)
        #expect(weight.direction == .down)
    }

    @Test func `tiles get their series from one data set`() {
        // 40 days, so the weight trend (which follows weigh-ins slowly) has settled into the 0.1 kg/day loss.
        let metrics = (0 ..< 40).map { (offset: Int) -> DailyHealthMetrics in
            let steps = 1000 * max(10 - offset, 1)
            let active: Double? = offset == 2 ? nil : 400
            let basal: Double? = offset == 3 ? nil : 1600
            let sleep: Int? = offset == 0 ? 450 : nil
            let weight: Double = 80 + Double(offset) * 0.1
            let water: Double? = offset == 1 ? 500 : nil
            return DailyHealthMetrics(
                day: today.adding(days: -offset), steps: steps, activeKcal: active, basalKcal: basal,
                sleepAsleepMin: sleep, weightKg: weight, restingHR: 55, waterMl: water,
            )
        }
        let noon = today.date(atHour: 12)
        let snapshot = dashboardSnapshot(today: today, metrics: metrics) { data in
            data.hydrationIntakes = [
                today: [
                    FluidIntake(id: "w1", ml: 500, at: noon, kind: .water, source: .water, name: "Water"),
                    FluidIntake(id: "d1", ml: 250, at: noon, kind: .other, source: .diary, name: "Cola"),
                ],
                today.adding(days: -5): [
                    FluidIntake(id: "w2", ml: 250, at: today.adding(days: -5).date(atHour: 12), kind: .water, source: .water, name: "Water"),
                ],
            ]
        }

        let steps = snapshot.sparklines[.steps]
        #expect(steps?.points.count == 7)
        #expect(steps?.mark == .bar)
        #expect(steps?.points.last?.value == 10000)
        #expect(snapshot.sparkline(for: .steps)?.direction == .up)

        // Total energy only on days with both parts.
        let total = snapshot.sparklines[.totalEnergy]
        #expect(total?.points.map(\.index) == [0, 1, 2, 5, 6])
        #expect(total?.points.last?.value == 2000)
        // Each bar is resting with active on top.
        #expect(total?.points.allSatisfy { $0.base == 1600 } == true)
        #expect(steps?.points.allSatisfy { $0.base == nil } == true)

        // Hydration: every drink logged in Vitalion plus other apps' water, days with neither are gaps.
        let water = snapshot.sparklines[.water]
        #expect(water?.points.map(\.index) == [1, 5, 6])
        #expect(water?.points.map(\.value) == [250, 500, 750])

        // Weight is the trend (a line), falling as the weights do.
        #expect(snapshot.sparklines[.weight]?.mark == .line)
        #expect(snapshot.sparkline(for: .weight)?.direction == .down)
        #expect(snapshot.accessibilityTrend(of: .weight, state: .ready) == "down over 7 days")
        #expect(snapshot.accessibilityTrend(of: .weight, state: .needsAccess) == nil)

        // Sleep: one night only, so nothing to draw yet; no HRV or body fat either.
        #expect(snapshot.sparklines[.sleep]?.points.map(\.value) == [450])
        #expect(snapshot.sparkline(for: .sleep) == nil)
        #expect(snapshot.sparkline(for: .hrv) == nil)
        #expect(snapshot.sparkline(for: .bodyFat) == nil)
        #expect(snapshot.sparkline(for: .restingHeartRate)?.direction == .steady)
        #expect(snapshot.sparkline(for: .energy) == nil)
    }
}

// MARK: - Total energy

struct TotalEnergyTests {
    let today = LocalDay("2026-11-09")!

    @Test func `with one part known it is shown under its own name, never as the total`() {
        let activeOnly = dashboardSnapshot(today: today, metrics: [DailyHealthMetrics(day: today, activeKcal: 420)])
        #expect(activeOnly.energyBurned?.totalKcal == nil)
        #expect(activeOnly.energyBurned?.activeKcal == 420)
        #expect(activeOnly.state(of: .totalEnergy, access: .requested, isFirstSync: false) == .ready)
        #expect(activeOnly.accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish)
            == "Total energy, active 420 calories, close to the active goal of 500, resting energy unknown, no total yet")

        let restingOnly = dashboardSnapshot(today: today, metrics: [DailyHealthMetrics(day: today, basalKcal: 1650)])
        #expect(restingOnly.energyBurned?.totalKcal == nil)
        #expect(restingOnly.accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish)
            == "Total energy, active energy unknown, resting 1,650 calories, no total yet")
    }

    @Test func `a partial day hides the total energy sparkline and its spoken trend`() {
        let history = (1 ... 6).map { DailyHealthMetrics(day: today.adding(days: -$0), activeKcal: 400, basalKcal: 1600) }
        let partial = dashboardSnapshot(today: today, metrics: history + [DailyHealthMetrics(day: today, activeKcal: 420)])
        #expect(partial.sparklines[.totalEnergy]?.isDrawable == true) // the series exists…
        #expect(partial.sparkline(for: .totalEnergy) == nil) // …but isn't shown next to a partial value
        #expect(partial.accessibilityTrend(of: .totalEnergy, state: .ready) == nil)

        let complete = dashboardSnapshot(
            today: today, metrics: history + [DailyHealthMetrics(day: today, activeKcal: 420, basalKcal: 1600)],
        )
        #expect(complete.sparkline(for: .totalEnergy) != nil)
        #expect(complete.accessibilityTrend(of: .totalEnergy, state: .ready) == "steady over 7 days")
    }

    @Test func `with neither part the tile has no value`() {
        let none = dashboardSnapshot(today: today, metrics: [DailyHealthMetrics(day: today)])
        #expect(none.energyBurned == nil)
        #expect(none.state(of: .totalEnergy, access: .requested, isFirstSync: false) == .noData(HealthKitClient.noDataMessage))
        #expect(none.state(of: .totalEnergy, access: .notRequested, isFirstSync: false) == .needsAccess)
    }
}
