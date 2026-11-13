import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct SupplementRepositoryTests {
    // 2026-11-09 is a Monday (weekday 2).
    let monday = day("2026-11-09")

    func key(_ id: String, _ day: LocalDay, _ minute: Int) -> SupplementDoseKey {
        SupplementDoseKey(supplementID: id, slot: SupplementSlot(day: day, minute: minute))
    }

    @discardableResult
    func add(
        _ f: Fixture, _ name: String, times: [Int], weekdays: Set<Int> = [], start: LocalDay? = nil, reminders: Bool = true,
    ) throws -> Supplement {
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        return try repo.save(Supplement(
            name: name, dose: "1 tablet", schedule: SupplementSchedule(times: times, weekdays: weekdays),
            startDay: start ?? monday, remindersEnabled: reminders,
        ))
    }

    @Test func `saves, trims, orders and deletes supplements`() throws {
        let f = try Fixture()
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        let d3 = try add(f, "  Vitamin D3 ", times: [480])
        let mg = try add(f, "Magnesium", times: [1260])
        #expect(d3.name == "Vitamin D3")
        #expect(try repo.supplements().map(\.name) == ["Vitamin D3", "Magnesium"])
        #expect(d3.schedule.times == [480])

        var edited = mg
        edited.schedule = SupplementSchedule(times: [1200, 480], weekdays: [2, 4])
        edited.note = "  "
        let saved = try repo.save(edited)
        #expect(saved.schedule == SupplementSchedule(times: [480, 1200], weekdays: [2, 4]))
        #expect(saved.note == nil)
        #expect(saved.revision == 2)

        try repo.reorder([mg.id, d3.id])
        #expect(try repo.supplements().map(\.name) == ["Magnesium", "Vitamin D3"])

        try repo.delete(id: mg.id)
        #expect(try repo.supplements().map(\.name) == ["Vitamin D3"])

        #expect(throws: Persistence.PersistenceError.self) {
            try repo.save(Supplement(name: " ", schedule: .asNeeded, startDay: monday))
        }
    }

    @Test func `a day lists the scheduled doses in time order, then extra doses`() throws {
        let f = try Fixture()
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        let mg = try add(f, "Magnesium", times: [1260])
        let d3 = try add(f, "Vitamin D3", times: [480])
        let mondays = try add(f, "Iron", times: [480], weekdays: [2])
        let ibu = try add(f, "Ibuprofen", times: [])
        let later = try add(f, "New", times: [600], start: monday.next)

        var dayView = try repo.day(monday)
        #expect(dayView.rows.map(\.supplement.name) == ["Vitamin D3", "Iron", "Magnesium"])
        #expect(dayView.progress == (0, 3))
        #expect(try repo.day(monday.next).rows.map(\.supplement.name) == ["Vitamin D3", "New", "Magnesium"])

        let morning = monday.startDate().addingTimeInterval(8 * 3600 + 600)
        try repo.markTaken([key(d3.id, monday, 480), key(mondays.id, monday, 480)], at: morning)
        try repo.markSkipped([key(mg.id, monday, 1260)])
        try repo.logExtra(supplementID: ibu.id, day: monday, at: morning)
        dayView = try repo.day(monday)
        #expect(dayView.rows.map(\.supplement.name) == ["Vitamin D3", "Iron", "Magnesium", "Ibuprofen"])
        #expect(dayView.rows.map(\.isTaken) == [true, true, false, true])
        #expect(dayView.rows[2].isSkipped)
        #expect(dayView.rows[0].dose?.takenAt == morning)
        #expect(dayView.progress == (2, 3))
        _ = later

        // Taken again replaces the row instead of adding one; clearing opens the dose again.
        try repo.markTaken([key(mg.id, monday, 1260)], at: morning)
        #expect(try repo.day(monday).doses.count(where: { $0.supplementID == mg.id }) == 1)
        try repo.clear(key(mg.id, monday, 1260))
        #expect(try repo.day(monday).rows[2].dose == nil)
        try repo.markTaken([key(mg.id, monday, 1260)], at: morning) // after a tombstone
        #expect(try repo.day(monday).rows[2].isTaken)
    }

    @Test func `logged doses stay visible after the schedule or the supplement changes`() throws {
        let f = try Fixture()
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        var d3 = try add(f, "Vitamin D3", times: [480])
        try repo.markTaken([key(d3.id, monday, 480)], at: monday.startDate())
        d3.schedule = SupplementSchedule(times: [540])
        d3.isActive = false
        try repo.save(d3)
        let rows = try repo.day(monday).rows
        #expect(rows.map(\.minute) == [480])
        #expect(rows.first?.isTaken == true)
    }

    @Test func `reminder input holds the reminded supplements and the handled doses`() throws {
        let f = try Fixture()
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        let d3 = try add(f, "Vitamin D3", times: [480])
        try add(f, "Quiet", times: [480], reminders: false)
        try add(f, "As needed", times: [])
        var off = try add(f, "Off", times: [480])
        off.isActive = false
        try repo.save(off)
        try repo.markSkipped([key(d3.id, monday, 480)])
        let input = try repo.reminderInput(in: monday ... monday.adding(days: 6))
        #expect(input.items.map(\.name) == ["Vitamin D3"])
        #expect(input.handled == [key(d3.id, monday, 480)])
    }

    @Test func `supplements are exported and imported`() throws {
        let f = try Fixture()
        let repo = SupplementRepository(f.db, clock: f.clock.appClock)
        let d3 = try add(f, "Vitamin D3", times: [480])
        try repo.markTaken([key(d3.id, monday, 480)], at: monday.startDate())
        let data = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()

        let other = try Fixture()
        try DataPortability(other.db, clock: other.clock.appClock).importJSON(data, mode: .replace)
        let restored = SupplementRepository(other.db, clock: other.clock.appClock)
        #expect(try restored.supplements().map(\.name) == ["Vitamin D3"])
        #expect(try restored.day(monday).progress == (1, 1))
    }

    @Test func `the tables check their values`() throws {
        let f = try Fixture()
        let d3 = try add(f, "Vitamin D3", times: [480])
        let stamp = "2026-11-09T08:00:00.000Z"
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO supplement_dose (id, supplement_id, day, scheduled_minute, status, created_at, updated_at)
                VALUES ('x', ?, '2026-11-09', 480, 'eaten', ?, ?)
                """, arguments: [d3.id, stamp, stamp])
            }
        }
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO supplement_dose (id, supplement_id, day, scheduled_minute, status, created_at, updated_at)
                VALUES ('y', ?, '2026-11-09', 1440, 'taken', ?, ?)
                """, arguments: [d3.id, stamp, stamp])
            }
        }
    }
}
