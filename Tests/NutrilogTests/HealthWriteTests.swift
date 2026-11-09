import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Nutrilog

/// Writing diary and water entries to Health (backlog #27).
@MainActor
struct HealthWriteServiceTests {
    let clock = ManualClock()
    let source = FakeHealthDataSource()
    let writer: FakeHealthWriter
    let env: AppEnvironment

    init() {
        writer = FakeHealthWriter(mirror: source)
        env = AppEnvironment.preview(clock: clock.appClock, health: source, healthWriter: writer)
    }

    var service: HealthWriteService {
        env.healthWrites!
    }

    var links: HealthKitLinkRepository {
        HealthKitLinkRepository(env.db!, clock: clock.appClock)
    }

    var today: LocalDay {
        LocalDay.today(now: clock.appClock.now())
    }

    let full = Nutrients(kcal: 420, proteinG: 30, carbsG: 50, fatG: 12, fiberG: 6, sugarG: 9, satFatG: 3, sodiumMg: 800)

    func logQuickAdd(_ nutrients: Nutrients? = nil) throws -> DiaryEntry {
        try #require(env.diary).logQuickAdd(name: "Lunch", nutrients: nutrients ?? full, slotID: "lunch", day: today)
    }

    func values(_ id: String) -> [HealthWriteType: Double] {
        Dictionary(uniqueKeysWithValues: writer.snapshot.samples(for: id).map { ($0.type, $0.value) })
    }

    // MARK: Save / edit / delete / restore

    @Test func `saving an entry writes its nutrients with the entry id and stores links`() async throws {
        let entry = try logQuickAdd()
        await service.drain()

        #expect(values(entry.id) == [
            .dietaryEnergyConsumed: 420, .dietaryProtein: 30, .dietaryCarbohydrates: 50, .dietaryFatTotal: 12,
            .dietaryFiber: 6, .dietarySugar: 9, .dietarySodium: 800,
        ])
        let drafts = writer.snapshot.samples(for: entry.id)
        #expect(drafts.allSatisfy { $0.externalID == entry.id && $0.version == entry.revision && $0.date == entry.loggedAt })
        let stored = try links.links(for: .diaryEntry, id: entry.id)
        #expect(Set(stored.map(\.hkType)) == Set(HealthWriteType.dietaryNutrients.map(\.identifier)))
        #expect(Set(stored.map(\.hkUUID)) == Set(writer.snapshot.samples.map { $0.uuid.uuidString.lowercased() }))
        #expect(try links.pending().isEmpty)
        #expect(service.queuedCount == 0)
    }

    @Test func `the diary commit never waits for Health`() throws {
        // No drain has run: the entry is saved and queued, nothing is written yet.
        let entry = try logQuickAdd()
        #expect(try env.diary?.entry(id: entry.id) != nil)
        #expect(try links.pending().map(\.ownerID) == [entry.id])
        #expect(writer.snapshot.saveCalls.isEmpty)
    }

    @Test func `editing deletes the old samples and writes new ones`() async throws {
        let diary = try #require(env.diary)
        let food = try #require(env.foods).save(FoodDetail(food: Food(
            name: "Rice",
            per100: Nutrients(kcal: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3),
        )))
        .food
        let entry = try diary.log(food: food, quantity: .base(100), slotID: "lunch", day: today)
        await service.drain()
        let firstUUIDs = try Set(links.links(for: .diaryEntry, id: entry.id).map(\.hkUUID))

        try diary.updateQuantity(entryID: entry.id, quantity: .base(200))
        await service.drain()
        #expect(values(entry.id)[.dietaryEnergyConsumed] == 260)
        #expect(writer.snapshot.samples(for: entry.id).count == 4) // kcal, protein, carbs, fat
        #expect(writer.snapshot.samples(for: entry.id).allSatisfy { $0.version == 2 })
        #expect(writer.snapshot.deleteCalls.last?.externalID == entry.id)
        let newUUIDs = try Set(links.links(for: .diaryEntry, id: entry.id).map(\.hkUUID))
        #expect(newUUIDs.count == 4)
        #expect(newUUIDs.isDisjoint(with: firstUUIDs))

        // Quick-add edits and moves rewrite too; a move to another day dates the samples on that day.
        try diary.move(entryID: entry.id, toSlot: "dinner", day: today.previous)
        await service.drain()
        let dinnerHour = try #require(try diary.mealSlots().first { $0.id == "dinner" }).defaultStartHour
        let moved = try #require(writer.snapshot.samples(for: entry.id).first)
        #expect(LocalDay(moved.date) == today.previous)
        #expect(moved.date == today.previous.date(atHour: dinnerHour ?? 12))
        #expect(writer.snapshot.samples(for: entry.id).count == 4)
    }

    @Test func `deleting removes the samples and links, undo writes them again`() async throws {
        let diary = try #require(env.diary)
        let entry = try logQuickAdd()
        await service.drain()

        try diary.softDelete(entryIDs: [entry.id])
        await service.drain()
        #expect(writer.snapshot.samples.isEmpty)
        #expect(try links.links(for: .diaryEntry, id: entry.id).isEmpty)

        try diary.restore(entryIDs: [entry.id])
        await service.drain()
        #expect(values(entry.id)[.dietaryEnergyConsumed] == 420)
        #expect(writer.snapshot.samples(for: entry.id).allSatisfy { $0.version == 3 })
        #expect(try links.links(for: .diaryEntry, id: entry.id).count == 7)
    }

    @Test func `copy and duplicate write the new entries`() async throws {
        let diary = try #require(env.diary)
        let entry = try logQuickAdd()
        let copy = try diary.duplicate(entryID: entry.id)
        let copied = try diary.copy(from: today, to: today.next)
        await service.drain()
        for id in [entry.id, copy.id] + copied {
            #expect(values(id)[.dietaryEnergyConsumed] == 420)
        }
    }

    @Test func `water is written, deleted and restored`() async throws {
        let water = try #require(env.water)
        let glass = try water.add(ml: 330, day: today)
        await service.drain()
        #expect(values(glass.id) == [.dietaryWater: 330])
        #expect(try links.links(for: .waterEntry, id: glass.id).map(\.hkType) == [HealthWriteType.dietaryWater.identifier])

        try water.softDelete(ids: [glass.id])
        await service.drain()
        #expect(writer.snapshot.samples.isEmpty)
        #expect(try links.links(for: .waterEntry, id: glass.id).isEmpty)

        try water.restore(ids: [glass.id])
        await service.drain()
        #expect(values(glass.id) == [.dietaryWater: 330])
    }

    @Test func `queued rows are drained automatically after the commit`() async throws {
        service.start()
        defer { service.stop() }
        let entry = try logQuickAdd()
        #expect(await waitUntil { !writer.snapshot.samples(for: entry.id).isEmpty })
        let glass = try #require(env.water).add(ml: 500, day: today)
        #expect(await waitUntil { !writer.snapshot.samples(for: glass.id).isEmpty })
        #expect(await waitUntil { (try? links.pending().isEmpty) == true })
    }

    // MARK: Toggle

    @Test func `toggle off stops writing and leaves existing samples untouched`() async throws {
        let diary = try #require(env.diary)
        let written = try logQuickAdd()
        await service.drain()
        let before = writer.snapshot.samples
        let deletesBefore = writer.snapshot.deleteCalls.count

        try service.setEnabled(false)
        #expect(try env.profiles?.setting(SettingKey.healthWriteEnabled, as: Bool.self) == false)
        let unwritten = try logQuickAdd()
        try diary.updateQuickAdd(entryID: written.id, name: nil, nutrients: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0))
        try diary.softDelete(entryIDs: [written.id])
        await service.runMaintenance() // orphan cleanup is paused too
        #expect(writer.snapshot.samples == before)
        #expect(writer.snapshot.samples(for: unwritten.id).isEmpty)
        #expect(writer.snapshot.deleteCalls.count == deletesBefore)
        #expect(writer.snapshot.saveCalls.count == 1)
        #expect(try links.pending().isEmpty)
        #expect(try links.links(for: .diaryEntry, id: written.id).count == 7) // still describes what is in Health

        // A new service reads the persisted setting.
        let reloaded = try HealthWriteService(
            writer: writer, links: links, diary: diary, water: #require(env.water), settings: #require(env.profiles),
        )
        #expect(!reloaded.isEnabled)

        // Back on: new changes are written again.
        try service.setEnabled(true)
        let later = try logQuickAdd()
        await service.drain()
        #expect(values(later.id)[.dietaryEnergyConsumed] == 420)
        #expect(writer.snapshot.samples(for: unwritten.id).isEmpty) // no backfill of changes made while off
    }

    // MARK: Failures and permissions

    @Test func `a failed write keeps the entry and is retried`() async throws {
        writer.update { $0.saveError = HealthDataError.unavailable }
        let entry = try logQuickAdd()
        await service.drain()
        #expect(try env.diary?.entry(id: entry.id) != nil)
        let pending = try links.pending()
        #expect(pending.map(\.ownerID) == [entry.id])
        #expect(pending.first?.attempts == 1)
        #expect(pending.first?.lastError != nil)
        #expect(service.failedCount == 1)
        #expect(service.lastError != nil)

        await service.drain()
        #expect(try links.pending().first?.attempts == 2)

        writer.update { $0.saveError = nil }
        await service.runMaintenance()
        #expect(values(entry.id).count == 7)
        #expect(try links.pending().isEmpty)
        #expect(service.failedCount == 0)
        #expect(service.lastError == nil)
    }

    @Test func `only allowed types are written`() async throws {
        writer.update {
            $0.authorization[.dietarySodium] = .denied
            $0.authorization[.dietarySugar] = .notDetermined
        }
        let entry = try logQuickAdd()
        await service.drain()
        #expect(Set(values(entry.id).keys) == HealthWriteType.dietaryNutrients.subtracting([.dietarySodium, .dietarySugar]))
        #expect(try links.links(for: .diaryEntry, id: entry.id).count == 5)
        #expect(try links.pending().isEmpty)

        // Nothing allowed at all (never connected): handled, nothing written, nothing left queued.
        writer.update { state in
            for type in HealthWriteType.allCases {
                state.authorization[type] = .notDetermined
            }
        }
        let other = try logQuickAdd()
        await service.drain()
        #expect(values(other.id).isEmpty)
        #expect(try links.pending().isEmpty)
    }

    @Test func `nothing is written on a device without Health`() async throws {
        let env = AppEnvironment.preview(clock: clock.appClock, healthWriter: FakeHealthWriter(isAvailable: false))
        let entry = try #require(env.diary).logQuickAdd(name: nil, nutrients: full, slotID: "lunch", day: today)
        await env.healthWrites?.drain()
        #expect(try HealthKitLinkRepository(#require(env.db)).pending().map(\.ownerID) == [entry.id]) // kept, harmless
    }

    // MARK: Orphan cleanup

    @Test func `orphan cleanup deletes the samples of deleted or missing rows`() async throws {
        let kept = try logQuickAdd()
        let deleted = try logQuickAdd()
        await service.drain()
        // A row that vanished (e.g. replaced by an import) and one deleted without its queue entry being processed.
        let ghost = try await writer.save(HealthSamples.water(ml: 250, date: clock.appClock.now(), externalID: "ghost", version: 1))
        try links.replaceLinks(for: .waterEntry, id: "ghost", with: [(HealthWriteType.dietaryWater.identifier, ghost[0].uuidString)])
        try env.diary?.softDelete(entryIDs: [deleted.id])
        try links.discardPending()

        await service.runMaintenance()
        #expect(writer.snapshot.samples(for: "ghost").isEmpty)
        #expect(writer.snapshot.samples(for: deleted.id).isEmpty)
        #expect(values(kept.id).count == 7)
        #expect(try links.orphans().isEmpty)
        #expect(try links.links(for: .diaryEntry, id: kept.id).count == 7)
    }

    @Test func `a failed orphan deletion keeps the links for the next launch`() async throws {
        let entry = try logQuickAdd()
        await service.drain()
        try env.diary?.softDelete(entryIDs: [entry.id])
        try links.discardPending()
        writer.update { $0.deleteError = HealthDataError.unavailable }
        await service.runMaintenance()
        #expect(try links.orphans().count == 1)
        writer.update { $0.deleteError = nil }
        await service.runMaintenance()
        #expect(try links.orphans().isEmpty)
        #expect(writer.snapshot.samples.isEmpty)
    }

    // MARK: Loop prevention

    @Test func `values read from Health are never written back`() async throws {
        let today = today
        let other = HealthSource(name: "WaterMinder", bundleIdentifier: "com.funnmedia.waterminder")
        source.update { state in
            state.authorizationRequested = true
            state.cumulativeSamples[.dietaryWater] = [HealthQuantitySample(start: today.date(atHour: 9), value: 400, source: other)]
            state.samples[.bodyMass] = [HealthQuantitySample(start: today.date(atHour: 7), value: 80, source: other)]
        }
        let sync = try #require(env.healthSync)
        await sync.refresh(force: true)
        #expect(try env.dailyMetrics?.metrics(on: today)?.waterMl == 400)
        await service.runMaintenance()
        #expect(writer.snapshot.saveCalls.isEmpty)
        #expect(try links.pending().isEmpty)
        #expect(try env.water?.entries(for: today).isEmpty == true) // other apps' water is not copied into water_entry
    }

    @Test func `water Nutrilog wrote is not read back as other apps' water`() async throws {
        let today = today
        let other = HealthSource(name: "WaterMinder", bundleIdentifier: "com.funnmedia.waterminder")
        source.update { state in
            state.authorizationRequested = true
            state.cumulativeSamples[.dietaryWater] = [HealthQuantitySample(start: today.date(atHour: 9), value: 400, source: other)]
        }
        // The writer mirrors into the fake source under Nutrilog's bundle id, exactly like Health would.
        try #require(env.water).add(ml: 500, day: today)
        await service.drain()
        #expect(source.snapshot.cumulativeSamples[.dietaryWater]?.count == 2)

        let sync = try HealthSyncService(
            source: source, ownBundleIdentifier: "hr.ivanjuric.nutrilog",
            metrics: #require(env.dailyMetrics), settings: #require(env.profiles), clock: clock.appClock,
        )
        try await sync.sync(days: today ... today)
        #expect(try env.dailyMetrics?.metrics(on: today)?.waterMl == 400)
        // The day's water = Nutrilog's entries + other apps — 900 ml, not 1400.
        #expect(try #require(env.water).totalMl(for: today) + (env.dailyMetrics?.metrics(on: today)?.waterMl ?? 0) == 900)
    }
}

/// Observer queries and background refresh (backlog #26).
@MainActor
struct HealthObserverTests {
    let clock = ManualClock()

    func makeEnvironment(authorized: Bool) -> (AppEnvironment, FakeHealthDataSource, FakeHealthObserver) {
        let today = LocalDay.today(now: clock.appClock.now())
        let fake = FakeHealthDataSource.demo(endingOn: today, days: 30)
        fake.update { $0.authorizationRequested = authorized }
        let observer = FakeHealthObserver()
        return (AppEnvironment.preview(clock: clock.appClock, health: fake, healthObserver: observer), fake, observer)
    }

    @Test func `observers are registered only after the user was asked`() async throws {
        let (env, _, observer) = makeEnvironment(authorized: false)
        let sync = try #require(env.healthSync)
        await sync.startObserving()
        #expect(!sync.isObserving)
        #expect(observer.snapshot.startCount == 0)

        try await sync.connect()
        await sync.waitForSync()
        #expect(sync.isObserving)
        #expect(observer.snapshot.observedTypes == HealthReadType.observedTypes)
        #expect(observer.snapshot.backgroundDeliveryTypes == Set(HealthReadType.observedTypes))
        await sync.startObserving() // idempotent
        #expect(observer.snapshot.startCount == 1)
    }

    @Test func `launch registers observers when access was granted before`() async {
        let (env, _, observer) = makeEnvironment(authorized: true)
        env.startHealthBackgroundWork()
        defer { env.healthWrites?.stop() }
        #expect(await waitUntil { observer.isObserving })
        #expect(observer.snapshot.observedTypes.count == 9)
    }

    @Test func `a new weigh-in reaches daily metrics and the observer is completed`() async throws {
        let (env, fake, observer) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.refresh()
        await sync.startObserving()
        let today = sync.today
        let scale = HealthSource(name: "Withings", bundleIdentifier: "com.withings.wiScaleNG")
        fake.update { state in
            state.samples[.bodyMass]?.removeAll { LocalDay($0.start) == today }
            state.samples[.bodyMass]?.append(HealthQuantitySample(start: today.date(atHour: 6), value: 77.7, source: scale))
        }
        clock.advance(hours: 0.1) // within the automatic-refresh throttle: observers are not throttled by it
        let fetchesBefore = fake.snapshot.fetchedRanges.count

        let completion = try #require(observer.fire(.bodyMass))
        #expect(await waitUntil { completion.isCompleted })
        #expect(try env.dailyMetrics?.metrics(on: today)?.weightKg == 77.7)
        #expect(fake.snapshot.fetchedRanges.count == fetchesBefore + 1)
        #expect(fake.snapshot.fetchedRanges.last == today.adding(days: -(HealthSyncService.recentDays - 1)) ... today)
        #expect(sync.observerRefreshCount == 1)
    }

    @Test func `observer completion is called on errors, failed refreshes and after stopping`() async throws {
        struct QueryFailed: Error {}
        let (env, fake, observer) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.startObserving()

        let failedQuery = try #require(observer.fire(.stepCount, error: QueryFailed()))
        #expect(failedQuery.isCompleted)

        fake.update { $0.fetchError = HealthDataError.unavailable }
        let failedRefresh = try #require(observer.fire(.sleepAnalysis))
        #expect(await waitUntil { failedRefresh.isCompleted })
        if case .failed = sync.phase {} else {
            Issue.record("expected a failed phase, got \(sync.phase)")
        }

        // A burst (as on launch, one update per type) is coalesced and every update completed.
        fake.update { $0.fetchError = nil }
        let burst = HealthReadType.observedTypes.compactMap { observer.fire($0) }
        #expect(burst.count == 9)
        #expect(await waitUntil { burst.allSatisfy(\.isCompleted) })
        #expect(sync.observerRefreshCount < 1 + 9)

        await sync.stopObserving()
        #expect(!sync.isObserving)
        #expect(observer.fire(.bodyMass) == nil) // queries stopped
    }

    @Test func `pull to refresh reads the full window and drains pending writes`() async throws {
        let (env, fake, _) = makeEnvironment(authorized: true)
        let sync = try #require(env.healthSync)
        await sync.refresh()
        let today = sync.today
        let before = fake.snapshot.fetchedRanges.count
        let entry = try #require(env.diary).logQuickAdd(
            name: nil, nutrients: Nutrients(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1), slotID: "lunch", day: today,
        )
        await env.refreshHealth()
        #expect(fake.snapshot.fetchedRanges.count == before + 3) // 90 days in three chunks, despite the throttle
        #expect(try HealthKitLinkRepository(#require(env.db)).links(for: .diaryEntry, id: entry.id).count == 4)
    }
}
