import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Migration 011 and the same repair after an import: days written under a non-Gregorian device calendar before
/// `LocalDay` always used the Gregorian one.
struct StoredDayMigrationTests {
    static let old = "2026-01-01T00:00:00.000Z"
    static let older = "2025-12-01T00:00:00.000Z"
    static let newer = "2026-11-11T08:00:00.000Z"

    /// A database migrated up to 009, as the app had it before the fix.
    /// A database as an app from before the fix left it: schema 9 (1.1.2) by default, or everything before the repair
    /// migration with `withCaffeine` (a build that already had migration 010).
    static func preFixDatabase(withCaffeine: Bool = false) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        let names = withCaffeine ? Array(Migrator.migrations.prefix(while: { $0 != "011_gregorian_days" })) : Array(Migrator.migrations.prefix(9))
        for name in names {
            migrator.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
        }
        try migrator.migrate(queue)
        return queue
    }

    // MARK: Raw inserts (the shape a pre-fix app wrote)

    static func diary(_ db: Database, _ id: String, day: String, table: String = "diary_entry") throws {
        let logged = table == "diary_entry" ? ", logged_at" : ""
        let loggedValue = table == "diary_entry" ? ", '2026-11-10T07:00:00.000Z'" : ""
        try db.execute(
            sql: """
            INSERT INTO \(table) (id, day, meal_slot_id, display_name, grams, kcal, protein_g, carbs_g, fat_g\(logged), created_at, updated_at)
            VALUES (?, ?, 'breakfast', 'Oats', 50, 190, 6, 30, 3\(loggedValue), ?, ?)
            """,
            arguments: [id, day, old, old],
        )
    }

    static func water(_ db: Database, _ id: String, day: String) throws {
        try db.execute(
            sql: "INSERT INTO water_entry (id, day, logged_at, ml, created_at, updated_at) VALUES (?, ?, '2026-11-10T07:00:00.000Z', 250, ?, ?)",
            arguments: [id, day, old, old],
        )
    }

    static func note(_ db: Database, day: String, text: String, complete: Bool, created: String = old, deleted: String? = nil) throws {
        try db.execute(
            sql: "INSERT INTO day_note (day, text, is_complete, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [day, text, complete, created, created, deleted],
        )
    }

    static func metrics(_ db: Database, day: String, steps: Int, fetched: String = old) throws {
        try db.execute(
            sql: "INSERT INTO daily_metrics (day, steps, fetched_at, updated_at) VALUES (?, ?, ?, ?)",
            arguments: [day, steps, fetched, fetched],
        )
    }

    static func target(_ db: Database, _ id: String, from day: String, kcal: Double, updated: String) throws {
        try db.execute(
            sql: """
            INSERT INTO target (id, effective_from, kcal, protein_g, carbs_g, fat_g, origin, created_at, updated_at)
            VALUES (?, ?, ?, 120, 200, 60, 'manual', ?, ?)
            """,
            arguments: [id, day, kcal, updated, updated],
        )
    }

    static func checkIn(_ db: Database, _ id: String, day: String, details: String?, updated: String) throws {
        try db.execute(
            sql: """
            INSERT INTO tdee_estimate (id, computed_for_day, window_days, logged_days, mean_intake_kcal, trend_start_kg, trend_end_kg,
                tdee_kcal, confidence, details_json, created_at, updated_at)
            VALUES (?, ?, 14, 12, 2100, 80, 79.6, 2400, 'medium', ?, ?, ?)
            """,
            arguments: [id, day, details, updated, updated],
        )
    }

    static func setting(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value, updated_at) VALUES (?, ?, ?)", arguments: [key, value, old])
    }

    /// A `TDEEEstimate` as `CheckInRepository` encodes it, with the given (possibly stale) days.
    static func details(day: String, start: String, days: [String]) -> String {
        let rows = days.map { #"{"day":"\#($0)","entryCount":3,"isComplete":true,"kcalIn":2100}"# }.joined(separator: ",")
        return #"{"baselineKcal":2300,"confidence":"medium","day":"\#(day)","days":[\#(rows)],"kcal":2400,"loggedDays":2,"#
            + #""meanIntakeKcal":2100,"rawKcal":2450,"trendEndKg":79.6,"trendSpanDays":13,"trendStartDay":"\#(start)","#
            + #""trendStartKg":80,"underLoggingSuspected":false,"wasClamped":false,"weighIns":9}"#
    }

    static func value(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> String? {
        try String.fetchOne(db, sql: sql, arguments: arguments)
    }

    // MARK: Buddhist device, every table

    /// Pre-fix rows from a Buddhist iPhone (Gregorian 2026-11-10 = "2569-11-10"), mixed with rows written after the fix.
    static func insertBuddhistHistory(_ db: Database) throws {
        try diary(db, "d1", day: "2569-11-10")
        try diary(db, "d2", day: "2567-02-29") // Buddhist leap day: not a Gregorian date at all
        try diary(db, "d3", day: "2026-11-11") // written after the fix
        try diary(db, "p1", day: "2569-11-12", table: "planned_entry")
        try diary(db, "p2", day: "2026-11-13", table: "planned_entry")
        try water(db, "w1", day: "2569-11-10")
        try water(db, "w2", day: "2026-11-10") // same Gregorian day as w1: both stay

        try note(db, day: "2569-11-10", text: "Pizza night", complete: true) // collides with a fresh note
        try note(db, day: "2026-11-10", text: "Walked home", complete: false, created: newer)
        try note(db, day: "2569-11-09", text: "Alone", complete: false) // no collision
        try note(db, day: "2569-11-08", text: "Gone", complete: true, deleted: old) // a tombstone vs a live note
        try note(db, day: "2026-11-08", text: "Kept", complete: false, created: newer)
        try note(db, day: "2569-11-07", text: "", complete: true) // empty stale note, fresh one has text
        try note(db, day: "2026-11-07", text: "Fresh", complete: false, created: newer)

        try metrics(db, day: "2569-11-10", steps: 100) // stale cache row; the Gregorian one stays
        try metrics(db, day: "2026-11-10", steps: 5000, fetched: newer)
        try metrics(db, day: "2569-11-09", steps: 200)

        try target(db, "t-stale", from: "2569-11-01", kcal: 2000, updated: old) // same day as t-fresh, older
        try target(db, "t-fresh", from: "2026-11-01", kcal: 2100, updated: newer)
        try target(db, "t-alone", from: "2569-10-01", kcal: 1900, updated: older)

        try checkIn(db, "e1", day: "2569-11-09",
                    details: details(day: "2569-11-08", start: "2569-10-26", days: ["2569-10-26", "2569-11-08"]), updated: old)
        try checkIn(db, "e-stale", day: "2569-11-02", details: nil, updated: older)
        try checkIn(db, "e-fresh", day: "2026-11-02", details: nil, updated: newer)

        try db.execute(sql: "UPDATE profile SET birth_date = '2533-05-01', updated_at = ?", arguments: [old])
        try setting(db, "checkInPromptedDay", #""2569-11-09""#)
        try setting(db, "energyUnit", #""kcal""#)
        try setting(db, "healthLastSyncedAt", "784000000.5")
    }

    static func assertBuddhistHistoryRepaired(_ db: Database) throws {
        // Diary, plan and water: every row kept, re-dated, stamped.
        #expect(try value(db, "SELECT day FROM diary_entry WHERE id = 'd1'") == "2026-11-10")
        #expect(try value(db, "SELECT day FROM diary_entry WHERE id = 'd2'") == "2024-02-29")
        #expect(try value(db, "SELECT day FROM diary_entry WHERE id = 'd3'") == "2026-11-11")
        #expect(try Int.fetchAll(db, sql: "SELECT revision FROM diary_entry ORDER BY id") == [2, 2, 1])
        #expect(try value(db, "SELECT updated_at FROM diary_entry WHERE id = 'd3'") == old)
        #expect(try value(db, "SELECT updated_at FROM diary_entry WHERE id = 'd1'") != old)
        #expect(try value(db, "SELECT day FROM planned_entry WHERE id = 'p1'") == "2026-11-12")
        #expect(try Int.fetchAll(db, sql: "SELECT revision FROM planned_entry ORDER BY id") == [2, 1])
        #expect(try String.fetchAll(db, sql: "SELECT day FROM water_entry ORDER BY id") == ["2026-11-10", "2026-11-10"])
        #expect(try Int.fetchAll(db, sql: "SELECT revision FROM water_entry ORDER BY id") == [2, 1])

        // Day notes: merged into the Gregorian row, tombstones carry no content.
        let notes = try Row.fetchAll(db, sql: "SELECT day, text, is_complete, revision FROM day_note ORDER BY day")
        #expect(notes.map { $0["day"] as String } == ["2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10"])
        #expect(notes.map { $0["text"] as String } == ["Fresh", "Kept", "Alone", "Pizza night\n\nWalked home"])
        #expect(notes.map { $0["is_complete"] as Bool } == [true, false, false, true])
        #expect(notes.map { $0["revision"] as Int } == [2, 1, 2, 2]) // "Kept" was not changed

        // Daily metrics: the Gregorian cache row wins.
        let metrics = try Row.fetchAll(db, sql: "SELECT day, steps, revision FROM daily_metrics ORDER BY day")
        #expect(metrics.map { $0["day"] as String } == ["2026-11-09", "2026-11-10"])
        #expect(metrics.map { $0["steps"] as Int } == [200, 5000])
        #expect(metrics.map { $0["revision"] as Int } == [2, 1])

        // Targets: nothing deleted; the older of two live targets on a day is retired.
        let targets = try Row.fetchAll(db, sql: "SELECT id, effective_from, deleted_at, revision FROM target ORDER BY id")
        #expect(targets.map { $0["id"] as String } == ["t-alone", "t-fresh", "t-stale"])
        #expect(targets.map { $0["effective_from"] as String } == ["2026-10-01", "2026-11-01", "2026-11-01"])
        #expect(targets.map { ($0["deleted_at"] as String?) != nil } == [false, false, true])
        #expect(targets.map { $0["revision"] as Int } == [2, 1, 2])

        // Check-ins: re-dated with their details; one per day, the newer stays.
        #expect(try String.fetchAll(db, sql: "SELECT id FROM tdee_estimate ORDER BY id") == ["e-fresh", "e1"])
        let record = try #require(try CheckInRecord.fetchOne(db, key: "e1"))
        #expect(record.computedForDay == LocalDay("2026-11-09"))
        #expect(record.revision == 2)
        let estimate = try #require(record.estimate)
        #expect(estimate.day == LocalDay("2026-11-08"))
        #expect(estimate.trendStartDay == LocalDay("2026-10-26"))
        #expect(estimate.days.map(\.day.isoString) == ["2026-10-26", "2026-11-08"])
        #expect(try value(db, "SELECT revision FROM tdee_estimate WHERE id = 'e-fresh'") == "1")

        // Profile birth date and settings.
        #expect(try value(db, "SELECT birth_date FROM profile") == "1990-05-01")
        #expect(try value(db, "SELECT revision FROM profile") == "2")
        #expect(try value(db, "SELECT value FROM setting WHERE key = 'checkInPromptedDay'") == #""2026-11-09""#)
        #expect(try value(db, "SELECT value FROM setting WHERE key = 'energyUnit'") == #""kcal""#)
        #expect(try value(db, "SELECT updated_at FROM setting WHERE key = 'energyUnit'") == old)
        #expect(try value(db, "SELECT value FROM setting WHERE key = 'healthLastSyncedAt'") == "784000000.5")
    }

    @Test func `migration 011 repairs a buddhist history in every table`() throws {
        let queue = try Self.preFixDatabase()
        try queue.write(Self.insertBuddhistHistory)
        try Migrator.make(deviceCalendar: .buddhist).migrate(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        try queue.read(Self.assertBuddhistHistoryRepaired)
        // Nothing is queued for Apple Health: nutrients and timestamps are unchanged.
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM healthkit_outbox") } == 0)

        // Idempotent: a second run (or a later import's run) changes nothing.
        let changes = try queue.write { db in
            try StoredDayMigration.run(db, deviceCalendar: .buddhist, today: LocalDay(year: 2026, month: 11, day: 11)!, now: Date())
        }
        #expect(changes == 0)
        // Opening the app database afterwards applies nothing more.
        _ = try AppDatabase(queue)
        try queue.read(Self.assertBuddhistHistoryRepaired)
    }

    @Test func `caffeine drinks logged before the fix move to their gregorian day`() throws {
        // A database already on the caffeine schema (migration 010) when the repair arrives.
        let queue = try Self.preFixDatabase(withCaffeine: true)
        let old = "2026-11-10T07:00:00.000Z"
        try queue.write { db in
            for (id, day) in [("c1", "2569-11-10"), ("c2", "2026-11-10")] {
                try db.execute(
                    sql: "INSERT INTO caffeine_entry (id, day, logged_at, mg, created_at, updated_at) VALUES (?, ?, ?, 80, ?, ?)",
                    arguments: [id, day, old, old, old],
                )
            }
        }
        try Migrator.make(deviceCalendar: .buddhist).migrate(queue)
        let days = try queue.read { db in try String.fetchAll(db, sql: "SELECT day FROM caffeine_entry ORDER BY id") }
        let revisions = try queue.read { db in try Int.fetchAll(db, sql: "SELECT revision FROM caffeine_entry ORDER BY id") }
        #expect(days == ["2026-11-10", "2026-11-10"])
        #expect(revisions == [2, 1])
    }

    @Test func `a device switched back to gregorian infers the buddhist days`() throws {
        let queue = try Self.preFixDatabase()
        try queue.write(Self.insertBuddhistHistory)
        try Migrator.make(deviceCalendar: .gregorian).migrate(queue)
        try queue.read(Self.assertBuddhistHistoryRepaired)
    }

    @Test func `persian japanese and hebrew days are repaired and impossible ones left alone`() throws {
        let queue = try Self.preFixDatabase()
        try queue.write { db in
            try Self.diary(db, "fa1", day: "1405-06-31") // 31 Shahrivar: not a Gregorian date (June has 30 days)
            try Self.diary(db, "fa2", day: "1405-08-20")
            try Self.diary(db, "fa3", day: "1405-07-31") // reached by old Gregorian day arithmetic; no such Persian day
            try Self.diary(db, "ja1", day: "0008-11-11") // written while the phone was set to Japanese
            try Self.diary(db, "he1", day: "5786-13-19") // Hebrew Elul
            try Self.water(db, "w1", day: "1405-08-19")
            try Self.note(db, day: "1405-08-20", text: "Persian", complete: false)
            try Self.note(db, day: "0008-11-11", text: "Japanese", complete: true, created: Self.newer) // the same Gregorian day
            try Self.metrics(db, day: "1405-08-19", steps: 10)
            try Self.metrics(db, day: "0008-11-10", steps: 20, fetched: Self.newer) // also 2026-11-10: freshest wins
            try db.execute(sql: "UPDATE profile SET birth_date = '1369-02-11'")
        }
        try Migrator.make(deviceCalendar: .persian).migrate(queue)
        try queue.read { db in
            #expect(try String.fetchAll(db, sql: "SELECT day FROM diary_entry ORDER BY id")
                == ["2026-09-22", "2026-11-11", "1405-07-31", "2026-09-01", "2026-11-11"])
            #expect(try Int.fetchAll(db, sql: "SELECT revision FROM diary_entry ORDER BY id") == [2, 2, 1, 2, 2])
            #expect(try Self.value(db, "SELECT day FROM water_entry") == "2026-11-10")
            let note = try #require(try Row.fetchOne(db, sql: "SELECT * FROM day_note"))
            #expect(note["day"] as String == "2026-11-11")
            #expect(note["text"] as String == "Persian\n\nJapanese")
            #expect(note["is_complete"] as Bool)
            #expect(try Row.fetchAll(db, sql: "SELECT day, steps FROM daily_metrics ORDER BY day").map { [$0["day"] as String, "\($0["steps"] as Int)"] }
                == [["2026-11-10", "20"]])
            #expect(try Self.value(db, "SELECT birth_date FROM profile") == "1990-05-01")
        }
    }

    @Test func `a chinese device calendar leaves everything alone`() throws {
        let queue = try Self.preFixDatabase()
        try queue.write { db in
            try Self.diary(db, "c1", day: "0043-09-21")
            try Self.diary(db, "c2", day: "0008-11-11") // Reiwa 8 or a Chinese cycle year? Not guessed.
        }
        try Migrator.make(deviceCalendar: .chinese).migrate(queue)
        #expect(try queue.read { try String.fetchAll($0, sql: "SELECT day FROM diary_entry ORDER BY id") } == ["0043-09-21", "0008-11-11"])
    }

    // MARK: A Gregorian database is not written

    @Test func `a gregorian database is untouched`() throws {
        // On the caffeine schema already, so the only migrations left to apply are the repair and later ones.
        let queue = try Self.preFixDatabase(withCaffeine: true)
        try queue.write { db in
            try Self.diary(db, "d1", day: "2026-11-10")
            try Self.diary(db, "d2", day: "2024-02-29")
            try Self.diary(db, "p1", day: "2026-11-12", table: "planned_entry")
            try Self.water(db, "w1", day: "2026-11-10")
            try Self.note(db, day: "2026-11-10", text: "Hello", complete: true)
            try Self.note(db, day: "2026-11-09", text: "Bye", complete: false, deleted: Self.old)
            try Self.metrics(db, day: "2026-11-10", steps: 5000)
            try Self.target(db, "t1", from: "2026-11-01", kcal: 2000, updated: Self.old)
            try Self.target(db, "t2", from: "2026-11-01", kcal: 2100, updated: Self.newer) // a pre-existing duplicate stays
            try Self.checkIn(db, "e1", day: "2026-11-09",
                             details: Self.details(day: "2026-11-08", start: "2026-10-26", days: ["2026-10-26"]), updated: Self.old)
            try db.execute(sql: "UPDATE profile SET birth_date = '1985-03-04', updated_at = ?", arguments: [Self.old])
            try Self.setting(db, "checkInPromptedDay", #""2026-11-09""#)
        }
        let tables = ["diary_entry", "planned_entry", "water_entry", "caffeine_entry", "day_note", "daily_metrics", "target",
                      "tdee_estimate", "profile", "setting"]
        // Later migrations add columns (e.g. 013); compare the columns there were before the repair.
        let columns = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: tables.map { try ($0, db.columns(in: $0).map(\.name).joined(separator: ", ")) })
        }
        func snapshot() throws -> [String: [Row]] {
            try queue.read { db in
                try Dictionary(uniqueKeysWithValues: tables.map { table in
                    try (table, Row.fetchAll(db, sql: "SELECT \(columns[table]!) FROM \(table) ORDER BY rowid"))
                })
            }
        }
        let before = try snapshot()
        for calendar: Calendar.Identifier in [.buddhist, .persian, .japanese, .hebrew, .gregorian] {
            let changes = try queue.write { db in
                try StoredDayMigration.run(db, deviceCalendar: calendar, today: LocalDay(year: 2026, month: 11, day: 11)!, now: Date())
            }
            #expect(changes == 0)
        }
        try Migrator.make(deviceCalendar: .buddhist).migrate(queue)
        #expect(try snapshot() == before)
    }

    // MARK: Import

    @Test func `importing a pre-fix export repairs its days`() throws {
        // Build the export from a database holding the old days, as a backup made before the fix would.
        let source = try Fixture()
        try source.db.writer.write(Self.insertBuddhistHistory)
        let export = try source.portability.exportJSON()
        #expect(String(bytes: export, encoding: .utf8)?.contains("2569-11-10") == true)

        let clock = TestClock(Date(timeIntervalSince1970: 1_794_400_000)) // 2026-11-11 ~12:27 UTC, after `newer`
        let replaced = try AppDatabase.inMemory()
        try DataPortability(replaced, clock: clock.appClock, deviceCalendar: .buddhist).importJSON(export, mode: .replace)
        try replaced.reader.read(Self.assertBuddhistHistoryRepaired)

        // Merge into a database that already has fresh rows for the same days; importing twice changes nothing more.
        let merged = try AppDatabase.inMemory()
        try merged.writer.write { db in
            try Self.note(db, day: "2026-11-09", text: "Already here", complete: false, created: Self.newer)
        }
        let portability = DataPortability(merged, clock: clock.appClock, deviceCalendar: .gregorian)
        try portability.importJSON(export, mode: .merge)
        let snapshot = { try merged.reader.read { db in try Row.fetchAll(db, sql: "SELECT * FROM day_note ORDER BY day") } }
        let first = try snapshot()
        #expect(first.first { ($0["day"] as String) == "2026-11-09" }?["text"] as String? == "Alone\n\nAlready here")
        #expect(try merged.reader.read { try Self.value($0, "SELECT day FROM diary_entry WHERE id = 'd1'") } == "2026-11-10")
        try portability.importJSON(export, mode: .merge)
        let second = try snapshot()
        #expect(second == first, "\(first) → \(second)")
        #expect(try merged.reader.read { try Self.value($0, "SELECT day FROM diary_entry WHERE id = 'd1'") } == "2026-11-10")
    }
}
