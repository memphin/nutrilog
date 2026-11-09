import Core
import Foundation
import Testing
@testable import Persistence

struct WeightRepositoryTests {
    func weights(_ f: Fixture) -> WeightRepository {
        WeightRepository(f.db, clock: f.clock.appClock)
    }

    func queued(_ f: Fixture) throws -> [String] {
        try f.healthLinks.pending().filter { $0.ownerTable == .weightEntry }.map(\.ownerID)
    }

    @Test func `add, edit, delete and restore queue the entry for Health`() throws {
        let f = try Fixture()
        let repo = weights(f)
        let entry = try repo.add(kg: 81.4, bodyFatPct: 18.2)
        #expect(entry.measuredAt == f.clock.now)
        #expect(entry.source == "manual")
        #expect(try queued(f) == [entry.id])
        try f.healthLinks.discardPending()

        let earlier = f.clock.now.addingTimeInterval(-3600)
        f.clock.advance(60)
        let edited = try repo.update(id: entry.id, kg: 81.0, bodyFatPct: nil, measuredAt: earlier)
        #expect(edited.kg == 81.0)
        #expect(edited.bodyFatPct == nil)
        #expect(edited.measuredAt == earlier)
        #expect(edited.revision == 2)
        #expect(try queued(f) == [entry.id])
        try f.healthLinks.discardPending()

        // An unchanged edit is not a change.
        try repo.update(id: entry.id, kg: 81.0, bodyFatPct: nil, measuredAt: earlier)
        #expect(try queued(f).isEmpty)

        try repo.softDelete(ids: [entry.id])
        #expect(try repo.latest() == nil)
        #expect(try queued(f) == [entry.id])
        try f.healthLinks.discardPending()
        try repo.restore(ids: [entry.id])
        #expect(try repo.latest()?.id == entry.id)
        #expect(try repo.entry(id: entry.id)?.revision == 4)
        #expect(try queued(f) == [entry.id])

        // A deleted entry can't be edited.
        try repo.softDelete(ids: [entry.id])
        #expect(throws: PersistenceError.self) { try repo.update(id: entry.id, kg: 80, bodyFatPct: nil, measuredAt: earlier) }
    }

    @Test func `validates kg and body fat`() throws {
        let f = try Fixture()
        #expect(throws: PersistenceError.validation("weight out of range")) { try weights(f).add(kg: 0) }
        #expect(throws: PersistenceError.validation("weight out of range")) { try weights(f).add(kg: .nan) }
        #expect(throws: PersistenceError.validation("body fat out of range")) { try weights(f).add(kg: 80, bodyFatPct: 90) }
        #expect(try f.healthLinks.pending().isEmpty)
    }

    @Test func `entries in an interval, oldest first; profile weights go through the same path`() throws {
        let f = try Fixture()
        let repo = weights(f)
        let now = f.clock.now
        let old = try repo.add(kg: 82, measuredAt: now.addingTimeInterval(-86400 * 3))
        let recent = try repo.add(kg: 81, measuredAt: now.addingTimeInterval(-3600))
        let fromProfile = try f.profiles.addWeight(kg: 80.5)
        let window = DateInterval(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(1))
        #expect(try repo.entries(in: window).map(\.id) == [recent.id, fromProfile.id])
        #expect(try f.profiles.latestWeight()?.id == fromProfile.id)
        #expect(try Set(queued(f)) == [old.id, recent.id, fromProfile.id])
    }

    @Test func `observation follows changes`() async throws {
        let f = try Fixture()
        let window = DateInterval(start: f.clock.now.addingTimeInterval(-86400), end: f.clock.now.addingTimeInterval(86400))
        var iterator = weights(f).observeEntries(in: window).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try weights(f).add(kg: 80)
        #expect(try await iterator.next()?.map(\.kg) == [80])
    }

    @Test func `recent unlinked weights are queued after access is granted, older ones are not`() throws {
        let f = try Fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = LocalDay(f.clock.now, calendar: calendar)
        let since = today.adding(days: -6)
        let recent = try weights(f).add(kg: 80, measuredAt: since.startDate(calendar: calendar))
        _ = try weights(f).add(kg: 81, measuredAt: since.startDate(calendar: calendar).addingTimeInterval(-1))
        let linked = try weights(f).add(kg: 82)
        try f.healthLinks.replaceLinks(for: .weightEntry, id: linked.id, with: [("HKQuantityTypeIdentifierBodyMass", "u1")])
        try f.healthLinks.discardPending()

        #expect(try f.healthLinks.enqueueUnlinked(since: since, calendar: calendar) == 1)
        #expect(try queued(f) == [recent.id])
    }

    @Test func `weights with body fat but no body fat sample are queued when body fat is allowed`() throws {
        let f = try Fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let since = LocalDay(f.clock.now, calendar: calendar).adding(days: -6)
        let massOnly = try weights(f).add(kg: 80, bodyFatPct: 18)
        let complete = try weights(f).add(kg: 81, bodyFatPct: 19)
        let noFat = try weights(f).add(kg: 82)
        let old = try weights(f).add(kg: 83, bodyFatPct: 20, measuredAt: since.startDate(calendar: calendar).addingTimeInterval(-1))
        let mass = "HKQuantityTypeIdentifierBodyMass"
        let fat = "HKQuantityTypeIdentifierBodyFatPercentage"
        try f.healthLinks.replaceLinks(for: .weightEntry, id: massOnly.id, with: [(mass, "u1")])
        try f.healthLinks.replaceLinks(for: .weightEntry, id: complete.id, with: [(mass, "u2"), (fat, "u3")])
        try f.healthLinks.replaceLinks(for: .weightEntry, id: noFat.id, with: [(mass, "u4")])
        try f.healthLinks.replaceLinks(for: .weightEntry, id: old.id, with: [(mass, "u5")])
        try f.healthLinks.discardPending()

        #expect(try f.healthLinks.enqueueWeights(missing: fat, since: since, calendar: calendar) == 1)
        #expect(try queued(f) == [massOnly.id])
    }

    @Test func `imports queue weights for Health`() throws {
        let source = try Fixture()
        let entry = try WeightRepository(source.db, clock: source.clock.appClock).add(kg: 79.9)
        let target = try Fixture()
        try DataPortability(target.db, clock: target.clock.appClock).importJSON(
            DataPortability(source.db, clock: source.clock.appClock).exportJSON(), mode: .merge,
        )
        #expect(try queued(target) == [entry.id])
    }
}
