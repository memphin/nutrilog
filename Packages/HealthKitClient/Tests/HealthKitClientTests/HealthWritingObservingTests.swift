import Core
import Foundation
import Synchronization
import Testing
@testable import HealthKitClient

private func zagreb() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
    return calendar
}

struct HealthSampleDraftTests {
    let calendar = zagreb()

    @Test func `dietary drafts skip missing and zero values`() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let drafts = HealthSamples.dietary(
            Nutrients(kcal: 250, proteinG: 10, carbsG: 0, fatG: 5.5, fiberG: nil, sugarG: 3, sodiumMg: 120),
            date: date, externalID: "e1", version: 3,
        )
        #expect(drafts.map(\.type) == [.dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietarySugar, .dietarySodium])
        #expect(drafts.map(\.value) == [250, 10, 5.5, 3, 120])
        #expect(drafts.allSatisfy { $0.date == date && $0.externalID == "e1" && $0.version == 3 })
        #expect(drafts[0].syncIdentifier == "e1.dietaryEnergyConsumed")
        #expect(Set(drafts.map(\.type)).isSubset(of: HealthWriteType.dietaryNutrients))
        #expect(HealthSamples.dietary(Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0), date: date, externalID: "e", version: 1).isEmpty)
    }

    @Test func `water draft`() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(HealthSamples.water(ml: 330, date: date, externalID: "w", version: 1).map(\.type) == [.dietaryWater])
        #expect(HealthSamples.water(ml: 0, date: date, externalID: "w", version: 1).isEmpty)
    }

    @Test func `sync version grows with every edit and every retry`() {
        #expect(HealthSamples.syncVersion(revision: 1, attempt: 1) == 1001)
        #expect(HealthSamples.syncVersion(revision: 1, attempt: 2) > HealthSamples.syncVersion(revision: 1, attempt: 1))
        #expect(HealthSamples.syncVersion(revision: 2, attempt: 1) > HealthSamples.syncVersion(revision: 1, attempt: 999))
        #expect(HealthSamples.syncVersion(revision: 1, attempt: 5000) == 1999) // clamped below the next revision
    }

    @Test func `units match the stored values`() {
        #expect(HealthWriteType.dietaryEnergyConsumed.unitSymbol == "kcal")
        #expect(HealthWriteType.dietaryProtein.unitSymbol == "g")
        #expect(HealthWriteType.dietarySodium.unitSymbol == "mg")
        #expect(HealthWriteType.dietaryWater.unitSymbol == "ml")
        #expect(HealthWriteType.bodyMass.unitSymbol == "kg")
    }

    @Test func `sample date is the log time on the entry's day, else the fallback hour`() throws {
        let day = try #require(LocalDay("2026-11-09"))
        let loggedToday = day.date(atHour: 8, calendar: calendar).addingTimeInterval(17 * 60)
        #expect(HealthSamples.date(day: day, loggedAt: loggedToday, calendar: calendar) == loggedToday)
        let loggedNextDay = day.next.date(atHour: 9, calendar: calendar)
        #expect(HealthSamples.date(day: day, loggedAt: loggedNextDay, fallbackHour: 19, calendar: calendar)
            == day.date(atHour: 19, calendar: calendar))
        #expect(HealthSamples.date(day: day, loggedAt: loggedNextDay, calendar: calendar) == day.date(atHour: 12, calendar: calendar))
    }
}

struct FakeHealthWriterTests {
    @Test func `saves, deletes by row and mirrors water into the fake source`() async throws {
        let source = FakeHealthDataSource()
        let writer = FakeHealthWriter(mirror: source)
        let date = try #require(LocalDay("2026-11-09")?.date(atHour: 10, calendar: zagreb()))
        let ids = try await writer.save(
            HealthSamples.water(ml: 500, date: date, externalID: "w1", version: 1)
                + HealthSamples.dietary(Nutrients(kcal: 100, proteinG: 1, carbsG: 2, fatG: 3), date: date, externalID: "d1", version: 1),
        )
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        #expect(source.snapshot.cumulativeSamples[.dietaryWater]?.map(\.value) == [500])
        #expect(try await writer.deleteSamples(externalID: "w1", types: [.dietaryWater]) == 1)
        #expect(source.snapshot.cumulativeSamples[.dietaryWater]?.isEmpty == true)
        #expect(try await writer.deleteSamples(externalID: "d1", types: [.dietaryProtein]) == 1)
        #expect(writer.snapshot.samples(for: "d1").map(\.type).sorted { $0.rawValue < $1.rawValue }
            == [.dietaryCarbohydrates, .dietaryEnergyConsumed, .dietaryFatTotal])
    }

    @Test func `denied types and injected errors throw`() async {
        let writer = FakeHealthWriter()
        writer.update { $0.authorization[.dietarySodium] = .denied }
        #expect(await writer.writeAuthorization(for: .dietarySodium) == .denied)
        #expect(await writer.writeAuthorization(for: .dietaryProtein) == .authorized)
        let draft = HealthSampleDraft(type: .dietarySodium, value: 1, date: .now, externalID: "x", version: 1)
        await #expect(throws: FakeHealthWriterError.notAuthorized(.dietarySodium)) { try await writer.save([draft]) }
        writer.update { $0.saveError = HealthDataError.unavailable }
        await #expect(throws: HealthDataError.unavailable) { try await writer.save([]) }
        #expect(writer.snapshot.samples.isEmpty)
    }
}

/// Collects refresh calls; a refresh can be held open until `release()`.
private final class RefreshProbe: Sendable {
    private let calls = Mutex<[Set<HealthReadType>]>([])
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let holds: Bool

    init(holds: Bool = false) {
        self.holds = holds
    }

    var recorded: [Set<HealthReadType>] {
        calls.withLock { $0 }
    }

    func refresh(_ types: Set<HealthReadType>) async {
        calls.withLock { $0.append(types) }
        guard holds else { return }
        await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
        }
    }

    func release() {
        gate.withLock { gate in
            gate?.resume()
            gate = nil
        }
    }

    var isHolding: Bool {
        gate.withLock { $0 != nil }
    }
}

/// Polls until `condition` holds or `timeout` passes.
private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private struct ObserverFailure: Error {}

struct HealthObserverDispatcherTests {
    func start(_ dispatcher: HealthObserverDispatcher) async throws -> FakeHealthObserver {
        let observer = FakeHealthObserver()
        try await observer.startObserving(HealthReadType.allCases) { dispatcher.handle($0) }
        return observer
    }

    @Test func `observes every metric type and enables background delivery`() async throws {
        let observer = try await start(HealthObserverDispatcher { _ in })
        #expect(HealthReadType.observedTypes.count == 9)
        #expect(!HealthReadType.observedTypes.contains(.dateOfBirth))
        #expect(observer.snapshot.observedTypes.allSatisfy { $0.kind != .characteristic })
        #expect(observer.snapshot.backgroundDeliveryTypes.contains(.bodyMass))
        #expect(observer.fire(.biologicalSex) == nil) // never observed
        await observer.stopObserving()
        #expect(observer.fire(.bodyMass) == nil)
        #expect(observer.snapshot.backgroundDeliveryTypes.contains(.bodyMass))
    }

    @Test func `background delivery failures are reported, observing continues`() async {
        let observer = FakeHealthObserver()
        observer.update { $0.failingBackgroundDelivery = [.sleepAnalysis] }
        await #expect(throws: HealthObserverError.backgroundDeliveryFailed([.sleepAnalysis])) {
            try await observer.startObserving(HealthReadType.observedTypes) { $0.completion.complete() }
        }
        #expect(observer.isObserving)
        #expect(observer.fire(.sleepAnalysis)?.isCompleted == true)
    }

    @Test func `completion is called after a successful refresh`() async throws {
        let probe = RefreshProbe()
        let dispatcher = HealthObserverDispatcher { await probe.refresh($0) }
        let observer = try await start(dispatcher)
        let completion = try #require(observer.fire(.bodyMass))
        #expect(await eventually { completion.isCompleted })
        #expect(probe.recorded == [[.bodyMass]])
    }

    @Test func `completion is called at once on an observer error, without a refresh`() async throws {
        let probe = RefreshProbe()
        let dispatcher = HealthObserverDispatcher { await probe.refresh($0) }
        let observer = try await start(dispatcher)
        let completion = try #require(observer.fire(.stepCount, error: ObserverFailure()))
        #expect(completion.isCompleted) // synchronously
        #expect(await eventually { true })
        await dispatcher.waitUntilIdle()
        #expect(probe.recorded.isEmpty)
    }

    @Test func `coalesced updates share one refresh and are all completed`() async throws {
        let probe = RefreshProbe(holds: true)
        let dispatcher = HealthObserverDispatcher { await probe.refresh($0) }
        let observer = try await start(dispatcher)
        let first = try #require(observer.fire(.bodyMass))
        #expect(await eventually { probe.isHolding })
        // Throttled: these arrive while the first refresh runs and wait for one shared refresh.
        let queued = try [.stepCount, .sleepAnalysis, .stepCount].map { try #require(observer.fire($0)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!first.isCompleted)
        #expect(queued.allSatisfy { !$0.isCompleted })
        probe.release()
        #expect(await eventually { first.isCompleted && probe.isHolding })
        #expect(queued.allSatisfy { !$0.isCompleted })
        probe.release()
        #expect(await eventually { queued.allSatisfy(\.isCompleted) })
        #expect(probe.recorded == [[.bodyMass], [.stepCount, .sleepAnalysis]])
    }

    @Test func `a refresh that hangs is completed by the timeout`() async throws {
        let probe = RefreshProbe(holds: true)
        let dispatcher = HealthObserverDispatcher(timeout: .milliseconds(50)) { await probe.refresh($0) }
        let observer = try await start(dispatcher)
        let completion = try #require(observer.fire(.restingHeartRate))
        #expect(await eventually { completion.isCompleted })
        #expect(probe.isHolding) // still running
        probe.release()
        await dispatcher.waitUntilIdle()
    }

    @Test func `stop completes waiting updates and every later one`() async throws {
        let probe = RefreshProbe(holds: true)
        let dispatcher = HealthObserverDispatcher { await probe.refresh($0) }
        let observer = try await start(dispatcher)
        let running = try #require(observer.fire(.bodyMass))
        #expect(await eventually { probe.isHolding })
        let waiting = try #require(observer.fire(.stepCount))
        try await Task.sleep(for: .milliseconds(20))
        await dispatcher.stop() // cancellation
        #expect(waiting.isCompleted)
        probe.release()
        #expect(await eventually { running.isCompleted })
        let late = try #require(observer.fire(.heartRateVariabilitySDNN))
        #expect(await eventually { late.isCompleted })
        #expect(probe.recorded == [[.bodyMass]])
    }

    @Test func `a completion runs its handler exactly once`() {
        let count = Mutex(0)
        let completion = HealthObserverCompletion { count.withLock { $0 += 1 } }
        #expect(!completion.isCompleted)
        completion.complete()
        completion.complete()
        #expect(completion.isCompleted)
        #expect(count.withLock { $0 } == 1)
    }
}
