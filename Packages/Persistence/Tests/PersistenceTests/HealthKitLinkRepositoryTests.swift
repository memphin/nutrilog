import Core
import Foundation
import Testing
@testable import Persistence

struct HealthKitOutboxTests {
    func queued(_ f: Fixture) throws -> [String] {
        try f.healthLinks.pending().map(\.ownerID)
    }

    @Test func `outbox is migrated (005) and not exported`() throws {
        let f = try Fixture()
        #expect(Migrator.migrations.contains("005_healthkit_outbox"))
        try f.healthLinks.enqueue(.diaryEntry, id: "a")
        let data = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: Any])
        #expect(tables["healthkit_outbox"] == nil)
        #expect(tables["healthkit_link"] != nil)
        #expect(!DataPortability.tables.contains("healthkit_outbox"))
    }

    func clear(_ f: Fixture) throws {
        for item in try f.healthLinks.pending() {
            try f.healthLinks.complete(item)
        }
    }

    @Test func `every diary change that affects Health queues the entry in the same transaction`() throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        let bread = try f.makeFood("Bread")
        let entry = try f.diary.log(food: bread, quantity: .base(50), slotID: "breakfast", day: today)
        #expect(try queued(f) == [entry.id])
        try clear(f)

        let quick = try f.diary.logQuickAdd(
            name: nil,
            nutrients: Nutrients(kcal: 300, proteinG: 1, carbsG: 2, fatG: 3),
            slotID: "lunch",
            day: today,
        )
        #expect(try queued(f) == [quick.id])
        try clear(f)

        try f.diary.updateQuantity(entryID: entry.id, quantity: .base(80))
        #expect(try queued(f) == [entry.id])
        try clear(f)

        try f.diary.updateQuickAdd(entryID: quick.id, name: "Out", nutrients: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0))
        #expect(try queued(f) == [quick.id])
        try clear(f)

        try f.diary.move(entryID: entry.id, toSlot: "dinner", day: today.previous)
        #expect(try queued(f) == [entry.id])
        try clear(f)

        let dup = try f.diary.duplicate(entryID: entry.id)
        #expect(try queued(f) == [dup.id])
        try clear(f)

        try f.diary.softDelete(entryIDs: [entry.id, dup.id, "missing"])
        #expect(try Set(queued(f)) == [entry.id, dup.id])
        try clear(f)
        try f.diary.softDelete(entryIDs: [entry.id]) // already deleted: nothing to do
        #expect(try queued(f).isEmpty)

        try f.diary.restore(entryIDs: [entry.id])
        #expect(try queued(f) == [entry.id])
        try clear(f)

        let copies = try f.diary.copy(from: today, to: today.next)
        #expect(try Set(queued(f)) == Set(copies))
        try clear(f)

        // Notes and reordering never touch Health.
        try f.diary.setNote(entryID: quick.id, note: "hi")
        try f.diary.reorder(day: today, slotID: "lunch", orderedIDs: [quick.id])
        try f.diary.setDayNote(day: today, text: "x")
        #expect(try queued(f).isEmpty)
        #expect(try f.healthLinks.pending().allSatisfy { $0.ownerTable == .diaryEntry })
    }

    @Test func `a failed change queues nothing`() throws {
        let f = try Fixture()
        #expect(throws: PersistenceError.self) { try f.diary.updateQuantity(entryID: "nope", quantity: .base(10)) }
        #expect(throws: PersistenceError.self) { try f.water.add(ml: 0, day: day("2026-11-09")) }
        #expect(try queued(f).isEmpty)
    }

    @Test func `re-queueing during processing keeps the row; attempts and failures are recorded`() throws {
        let f = try Fixture()
        try f.healthLinks.enqueue(.diaryEntry, id: "a")
        try f.healthLinks.enqueue(.waterEntry, id: "b")
        let first = try f.healthLinks.pending()
        #expect(first.map(\.ownerID) == ["a", "b"])
        #expect(first.map(\.generation) == [1, 2])

        let attemptA = try #require(try f.healthLinks.markAttempt(first[0]))
        #expect(attemptA.attempts == 1)
        try f.healthLinks.enqueue(.diaryEntry, id: "a") // edited again while the writer handles generation 1
        try f.healthLinks.complete(attemptA)
        #expect(try f.healthLinks.markAttempt(first[0]) == nil) // superseded
        let attemptB = try #require(try f.healthLinks.markAttempt(first[1]))
        try f.healthLinks.recordFailure(attemptB, error: "Health unavailable")
        let after = try f.healthLinks.pending()
        #expect(after.map(\.ownerID) == ["b", "a"])
        #expect(after[0].attempts == 1)
        #expect(after[0].lastError == "Health unavailable")
        #expect(after[1].generation == 3)
        #expect(after[1].attempts == 0)

        _ = try f.healthLinks.markAttempt(after[0])
        #expect(try f.healthLinks.pending()[0].attempts == 2)
        try f.healthLinks.enqueue(.waterEntry, id: "b") // queued again: a fresh start
        let requeued = try #require(try f.healthLinks.pending().first { $0.ownerID == "b" })
        #expect(requeued.attempts == 0)
        #expect(requeued.lastError == nil)

        try f.healthLinks.discardPending()
        #expect(try f.healthLinks.pending().isEmpty)
    }

    @Test func `generations are never reused after the queue was emptied`() throws {
        let f = try Fixture()
        try f.healthLinks.enqueue(.diaryEntry, id: "a")
        let inFlight = try #require(try f.healthLinks.pending().first)
        try f.healthLinks.discardPending() // writing turned off while generation 1 is being written
        try f.healthLinks.enqueue(.diaryEntry, id: "a") // turned on again, entry edited
        let requeued = try #require(try f.healthLinks.pending().first)
        #expect(requeued.generation > inFlight.generation)
        try f.healthLinks.complete(inFlight) // the old pass finishes
        #expect(try f.healthLinks.pending().map(\.ownerID) == ["a"])
    }

    @Test func `queue observation fires on enqueue but not on failures, completion or discard`() async throws {
        let f = try Fixture()
        var iterator = f.healthLinks.observeQueue().makeAsyncIterator()
        #expect(try await iterator.next() == 0)
        try f.healthLinks.enqueue(.diaryEntry, id: "a")
        #expect(try await iterator.next() == 1)
        let queuedItem = try #require(try f.healthLinks.pending().first)
        let item = try #require(try f.healthLinks.markAttempt(queuedItem))
        try f.healthLinks.recordFailure(item, error: "x") // must not re-trigger a drain
        try f.healthLinks.complete(item)
        try f.healthLinks.discardPending()
        try f.healthLinks.enqueue(.diaryEntry, id: "b")
        #expect(try await iterator.next() == 2)
    }

    @Test func `recent unlinked entries are queued after access is granted`() throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        let nutrients = Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0)
        let recent = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today.adding(days: -6))
        let old = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today.adding(days: -7))
        let linked = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        let deleted = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        let water = try f.water.add(ml: 250, day: today)
        try f.diary.softDelete(entryIDs: [deleted.id])
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: linked.id, with: [("HKA", "u1")])
        try f.healthLinks.discardPending()

        #expect(try f.healthLinks.enqueueUnlinked(since: today.adding(days: -6)) == 2)
        #expect(try Set(queued(f)) == [recent.id, water.id])
        _ = old
    }
}

struct HealthKitImportTests {
    let nutrients = Nutrients(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1)

    func queued(_ f: Fixture) throws -> Set<String> {
        try Set(f.healthLinks.pending().map(\.ownerID))
    }

    @Test func `replace import queues the old written rows and every imported active row`() throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        let inBackup = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        let deletedInBackup = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        try f.diary.softDelete(entryIDs: [deletedInBackup.id])
        let backup = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()

        // Logged and written to Health after the backup.
        let afterBackup = try f.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        let water = try f.water.add(ml: 300, day: today)
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: afterBackup.id, with: [("HKA", "u1")])
        try f.healthLinks.replaceLinks(for: .waterEntry, id: water.id, with: [("HKW", "u2")])
        try f.healthLinks.discardPending()

        try DataPortability(f.db, clock: f.clock.appClock).importJSON(backup, mode: .replace)
        #expect(try f.diary.entry(id: afterBackup.id) == nil)
        // The vanished rows (so their samples are deleted) and the active imported row (rewritten).
        #expect(try queued(f) == [afterBackup.id, water.id, inBackup.id])
    }

    @Test func `merge import queues inserted and updated diary and water rows`() throws {
        let source = try Fixture()
        let today = day("2026-11-09")
        let shared = try source.diary.logQuickAdd(name: nil, nutrients: nutrients, slotID: "lunch", day: today)
        let target = try Fixture()
        try DataPortability(target.db, clock: target.clock.appClock).importJSON(
            DataPortability(source.db, clock: source.clock.appClock).exportJSON(), mode: .merge,
        )
        #expect(try queued(target) == [shared.id])
        try target.healthLinks.discardPending()

        source.clock.advance(60)
        try source.diary.updateQuickAdd(entryID: shared.id, name: "Edited", nutrients: nutrients)
        let unchanged = try source.water.add(ml: 200, day: today)
        let newer = try DataPortability(source.db, clock: source.clock.appClock).exportJSON()
        try DataPortability(target.db, clock: target.clock.appClock).importJSON(newer, mode: .merge)
        #expect(try queued(target) == [shared.id, unchanged.id])

        // Importing the same file again changes nothing, so nothing is queued.
        try target.healthLinks.discardPending()
        try DataPortability(target.db, clock: target.clock.appClock).importJSON(newer, mode: .merge)
        #expect(try queued(target).isEmpty)
    }
}

struct HealthKitLinkTests {
    @Test func `links can be replaced for some types only`() throws {
        let f = try Fixture()
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: "e1", with: [("HKA", "u1"), ("HKB", "u2")])
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: "e1", types: ["HKA"], with: [("HKA", "u3")])
        #expect(try f.healthLinks.links(for: .diaryEntry, id: "e1").map(\.hkUUID) == ["u3", "u2"])
        try f.healthLinks.deleteLinks(for: .diaryEntry, id: "e1", types: ["HKA"])
        #expect(try f.healthLinks.links(for: .diaryEntry, id: "e1").map(\.hkUUID) == ["u2"])
    }

    @Test func `links are replaced per row`() throws {
        let f = try Fixture()
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: "e1", with: [("HKA", "u1"), ("HKB", "u2")])
        try f.healthLinks.replaceLinks(for: .waterEntry, id: "e1", with: [("HKW", "u3")])
        #expect(try f.healthLinks.links(for: .diaryEntry, id: "e1").map(\.hkUUID) == ["u1", "u2"])
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: "e1", with: [("HKA", "u4")])
        let links = try f.healthLinks.links(for: .diaryEntry, id: "e1")
        #expect(links.map(\.hkUUID) == ["u4"])
        #expect(links.first?.createdAt == f.clock.now)
        try f.healthLinks.deleteLinks(for: .diaryEntry, id: "e1")
        #expect(try f.healthLinks.links(for: .diaryEntry, id: "e1").isEmpty)
        #expect(try f.healthLinks.links(for: .waterEntry, id: "e1").count == 1)
    }

    @Test func `orphans are links whose row is deleted or missing`() throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        let kept = try f.diary.logQuickAdd(
            name: nil,
            nutrients: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: "lunch",
            day: today,
        )
        let deleted = try f.diary.logQuickAdd(
            name: nil,
            nutrients: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: "lunch",
            day: today,
        )
        let water = try f.water.add(ml: 250, day: today)
        let deletedWater = try f.water.add(ml: 300, day: today)
        try f.diary.softDelete(entryIDs: [deleted.id])
        try f.water.softDelete(ids: [deletedWater.id])
        for (owner, id) in [
            (HealthKitOwner.diaryEntry, kept.id), (.diaryEntry, deleted.id), (.diaryEntry, "gone"),
            (.waterEntry, water.id), (.waterEntry, deletedWater.id), (.weightEntry, "gone-weight"),
            (.waterEntry, kept.id), // a diary id under the wrong table is still an orphan
        ] {
            try f.healthLinks.replaceLinks(for: owner, id: id, with: [("HKA", newID()), ("HKB", newID())])
        }
        let orphans = try f.healthLinks.orphans()
        #expect(Set(orphans.map { "\($0.ownerTable.rawValue)/\($0.ownerID)" }) == [
            "diary_entry/\(deleted.id)", "diary_entry/gone", "water_entry/\(deletedWater.id)",
            "weight_entry/gone-weight", "water_entry/\(kept.id)",
        ])
        #expect(orphans.allSatisfy { $0.hkTypes == ["HKA", "HKB"] })
    }
}

struct WaterRepositoryTests {
    @Test func `add, list, total, delete and restore`() throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        let first = try f.water.add(ml: 330, day: today)
        f.clock.advance(60)
        let second = try f.water.add(ml: 500, day: today)
        try f.water.add(ml: 200, day: today.previous)
        #expect(first.loggedAt == first.createdAt)
        #expect(first.revision == 1)
        #expect(try f.water.entries(for: today).map(\.id) == [first.id, second.id])
        #expect(try f.water.totalMl(for: today) == 830)

        try f.water.softDelete(ids: [first.id])
        #expect(try f.water.totalMl(for: today) == 500)
        #expect(try f.water.entry(id: first.id)?.revision == 2)
        try f.water.restore(ids: [first.id])
        #expect(try f.water.totalMl(for: today) == 830)
        #expect(try f.water.entry(id: first.id)?.revision == 3)
        #expect(try f.healthLinks.pending().filter { $0.ownerTable == .waterEntry }.count == 3)
    }

    @Test func `rejects empty amounts`() throws {
        let f = try Fixture()
        #expect(throws: PersistenceError.validation("amount must be greater than zero")) {
            try f.water.add(ml: -1, day: day("2026-11-09"))
        }
    }

    @Test func `range observation lists the days' entries, not deleted ones`() async throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        try f.water.add(ml: 100, day: today.adding(days: -7)) // outside
        let old = try f.water.add(ml: 200, day: today.adding(days: -6))
        let deleted = try f.water.add(ml: 300, day: today.adding(days: -1))
        try f.water.softDelete(ids: [deleted.id])
        var iterator = f.water.observeEntries(in: today.adding(days: -6) ... today).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == [old.id])
        try f.water.add(ml: 250, day: today)
        #expect(try await iterator.next()?.map(\.ml) == [200, 250])
    }

    @Test func `observation follows the day`() async throws {
        let f = try Fixture()
        let today = day("2026-11-09")
        var iterator = f.water.observeEntries(for: today).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try f.water.add(ml: 250, day: today)
        #expect(try await iterator.next()?.map(\.ml) == [250])
    }
}
