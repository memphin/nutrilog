import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct TrainingDaysMigrationTests {
    @Test func `migration 015 adds the training tables and keeps existing data`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        let index = try #require(Migrator.migrations.firstIndex(of: "015_training_days"))
        for name in Migrator.migrations.prefix(index) {
            if let migrate = Migrator.codedMigration(named: name, deviceCalendar: .gregorian) {
                old.registerMigration(name, migrate: migrate)
            } else {
                old.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
            }
        }
        try old.migrate(queue)
        let stamp = "2026-01-01T00:00:00.000Z"
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO target (id, effective_from, kcal, protein_g, carbs_g, fat_g, origin, created_at, updated_at)
            VALUES ('t1', '2026-01-01', 2000, 150, 200, 70, 'manual', ?, ?)
            """, arguments: [stamp, stamp])
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)

        let (schedule, trainingDay) = try queue.read { db in
            try (db.columns(in: "training_schedule").map(\.name), db.columns(in: "training_day").map(\.name))
        }
        for column in ["id", "effective_from", "weekdays_json", "boost_percent", "created_at", "updated_at", "deleted_at", "revision"] {
            #expect(schedule.contains(column), "missing training_schedule.\(column)")
        }
        for column in ["day", "is_training", "created_at", "updated_at", "deleted_at", "revision"] {
            #expect(trainingDay.contains(column), "missing training_day.\(column)")
        }
        #expect(try ProfileRepository(db).target(on: day("2026-11-09"))?.kcal == 2000)
        // Nothing set yet: no training days, the default boost.
        let none = try TrainingDayRepository(db).trainingDays(in: day("2026-11-01") ... day("2026-11-30"))
        #expect(none == .none)
        #expect(DataPortability.tables.contains("training_schedule"))
        #expect(DataPortability.tables.contains("training_day"))
    }

    @Test func `boolean and boost are checked in the table too`() throws {
        let f = try Fixture()
        let stamp = "2026-11-09T08:00:00.000Z"
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO training_day (day, is_training, created_at, updated_at) VALUES ('2026-11-09', 2, ?, ?)
                """, arguments: [stamp, stamp])
            }
        }
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO training_schedule (id, effective_from, weekdays_json, boost_percent, created_at, updated_at)
                VALUES ('s', '2026-11-09', '[]', -5, ?, ?)
                """, arguments: [stamp, stamp])
            }
        }
    }
}

struct TrainingDayRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `a schedule is stored with its weekdays sorted`() throws {
        let f = try Fixture()
        let saved = try f.trainingDays.setSchedule(weekdays: [6, 2, 4], boostPercent: 15, effectiveFrom: monday)
        #expect(saved.weekdays == [2, 4, 6])
        #expect(saved.boostPercent == 15)
        let raw = try f.db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT weekdays_json FROM training_schedule")
        }
        #expect(raw == "[2,4,6]")
        #expect(try f.trainingDays.schedule(on: monday) == saved)
        #expect(try f.trainingDays.schedule(on: monday.previous) == nil)
    }

    @Test func `a schedule on the same day replaces it, a later one starts a new one`() throws {
        let f = try Fixture()
        try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 10, effectiveFrom: monday)
        f.clock.advance(60)
        try f.trainingDays.setSchedule(weekdays: [3], boostPercent: 20, effectiveFrom: monday)
        var rows = try f.trainingDays.scheduleHistory()
        #expect(rows.count == 1)
        #expect(rows[0].revision == 2)
        #expect(rows[0].updatedAt > rows[0].createdAt)
        #expect(rows[0].schedule == TrainingSchedule(effectiveFrom: monday, weekdays: [3], boostPercent: 20))

        try f.trainingDays.setSchedule(weekdays: [4], boostPercent: 5, effectiveFrom: monday.adding(days: 7))
        rows = try f.trainingDays.scheduleHistory()
        #expect(rows.map(\.effectiveFrom) == [monday.adding(days: 7), monday]) // newest first
        let timeline = try f.trainingDays.scheduleTimeline()
        #expect(timeline.value(on: monday.adding(days: 6))?.weekdays == [3])
        #expect(timeline.value(on: monday.adding(days: 7))?.weekdays == [4])
    }

    @Test func `a boost outside the range or an invalid weekday is rejected`() throws {
        let f = try Fixture()
        #expect(throws: Persistence.PersistenceError.self) {
            try f.trainingDays.setSchedule(weekdays: [2], boostPercent: -1, effectiveFrom: monday)
        }
        #expect(throws: Persistence.PersistenceError.self) {
            try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 101, effectiveFrom: monday)
        }
        #expect(throws: Persistence.PersistenceError.self) {
            try f.trainingDays.setSchedule(weekdays: [0, 2], boostPercent: 10, effectiveFrom: monday)
        }
        #expect(try f.trainingDays.scheduleHistory().isEmpty)
    }

    @Test func `an override is upserted and cleared`() throws {
        let f = try Fixture()
        try f.trainingDays.setTraining(true, on: monday)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [monday: true])
        f.clock.advance(60)
        try f.trainingDays.setTraining(false, on: monday)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [monday: false])
        try f.trainingDays.clearOverride(on: monday)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [:])
        // Cleared is a tombstone (for sync and backups); setting it again revives the row.
        let row = try #require(try f.db.reader.read { db in try TrainingDayOverride.fetchOne(db, key: monday) })
        #expect(row.deletedAt != nil)
        #expect(row.revision == 3)
        try f.trainingDays.setTraining(true, on: monday)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [monday: true])
        // Clearing a day without an override does nothing.
        try f.trainingDays.clearOverride(on: monday.next)
        #expect(try f.db.reader.read { db in try TrainingDayOverride.fetchCount(db) } == 1)
    }

    @Test func `overrides are limited to the range`() throws {
        let f = try Fixture()
        try f.trainingDays.setTraining(true, on: monday.previous)
        try f.trainingDays.setTraining(true, on: monday)
        try f.trainingDays.setTraining(false, on: monday.next)
        try f.trainingDays.setTraining(true, on: monday.adding(days: 2))
        #expect(try f.trainingDays.overrides(in: monday ... monday.next) == [monday: true, monday.next: false])
    }

    @Test func `the resolver combines schedules and overrides`() throws {
        let f = try Fixture()
        try f.trainingDays.setSchedule(weekdays: [2, 4], boostPercent: 10, effectiveFrom: day("2026-11-01"))
        try f.trainingDays.setSchedule(weekdays: [3], boostPercent: 20, effectiveFrom: monday.adding(days: 7))
        try f.trainingDays.setTraining(false, on: monday)
        try f.trainingDays.setTraining(true, on: monday.adding(days: 5)) // Saturday
        let days = try f.trainingDays.trainingDays(in: monday ... monday.adding(days: 13))
        #expect(!days.isTraining(monday))
        #expect(days.isTraining(monday.adding(days: 2))) // Wednesday, old schedule
        #expect(days.boost(on: monday.adding(days: 5)) == 10)
        #expect(!days.isTraining(monday.adding(days: 9))) // Wednesday, new schedule
        #expect(days.isTraining(monday.adding(days: 8))) // Tuesday, new schedule
        #expect(days.boost(on: monday.adding(days: 8)) == 20)
    }

    @Test func `observing training days follows schedule and override changes`() async throws {
        let f = try Fixture()
        var iterator = f.trainingDays.observeTrainingDays(in: monday ... monday.adding(days: 6)).makeAsyncIterator()
        #expect(try await iterator.next() == TrainingDays.none)
        try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 10, effectiveFrom: monday)
        #expect(try await iterator.next()?.isTraining(monday) == true)
        try f.trainingDays.setTraining(false, on: monday)
        #expect(try await iterator.next()?.isTraining(monday) == false)
        try f.trainingDays.clearOverride(on: monday)
        #expect(try await iterator.next()?.isTraining(monday) == true)
    }

    @Test func `a target is boosted for a training day`() {
        let target = Target(
            effectiveFrom: monday, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 70), fiberG: 30,
            origin: .manual,
        )
        let boosted = target.boosted(byPercent: 10)
        #expect(boosted.kcal == 2200)
        #expect(boosted.carbsG == 250)
        #expect(boosted.proteinG == 150)
        #expect(boosted.fatG == 70)
        #expect(boosted.fiberG == 30)
        #expect(boosted.id == target.id)
        #expect(target.boosted(byPercent: 0) == target)
    }

    @Test func `toggling a day keeps an override only while it differs from the schedule`() throws {
        let f = try Fixture()
        try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 10, effectiveFrom: monday)
        // Monday is a scheduled training day: switching it off is an override…
        #expect(try f.trainingDays.toggleTraining(on: monday) == false)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [monday: false])
        // …and switching it back on follows the schedule again.
        #expect(try f.trainingDays.toggleTraining(on: monday) == true)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [:])
        #expect(try f.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))

        // Tuesday is not scheduled: switching it on is an override, off again clears it.
        let tuesday = monday.next
        #expect(try f.trainingDays.toggleTraining(on: tuesday) == true)
        #expect(try f.trainingDays.overrides(in: tuesday ... tuesday) == [tuesday: true])
        #expect(try f.trainingDays.toggleTraining(on: tuesday) == false)
        #expect(try f.trainingDays.overrides(in: tuesday ... tuesday) == [:])

        // Without any schedule a toggled day is an override too.
        let before = monday.adding(days: -7)
        #expect(try f.trainingDays.toggleTraining(on: before) == true)
        #expect(try f.trainingDays.overrides(in: before ... before) == [before: true])
    }

    @Test func `the effective target is the base target, boosted on a training day`() throws {
        let f = try Fixture()
        #expect(try f.trainingDays.effectiveTarget(on: monday) == nil)
        let base = try f.profiles.setTarget(Target(
            effectiveFrom: monday.adding(days: -7), kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 70),
            origin: .manual,
        ))
        #expect(try f.trainingDays.effectiveTarget(on: monday) == base)

        try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 10, effectiveFrom: monday)
        let boosted = try #require(try f.trainingDays.effectiveTarget(on: monday))
        #expect(boosted.kcal == 2200)
        #expect(boosted.carbsG == 250)
        #expect(boosted.proteinG == 150)
        // A rest day, and a day before the schedule, keep the base target.
        #expect(try f.trainingDays.effectiveTarget(on: monday.next) == base)
        #expect(try f.trainingDays.effectiveTarget(on: monday.adding(days: -7)) == base)
        // An override counts.
        try f.trainingDays.setTraining(true, on: monday.next)
        #expect(try f.trainingDays.effectiveTarget(on: monday.next)?.kcal == 2200)
        // The resolver does the same with a target in hand; no target stays none.
        let days = try f.trainingDays.trainingDays(in: monday ... monday.next)
        #expect(days.effectiveTarget(base, on: monday)?.kcal == 2200)
        #expect(days.effectiveTarget(nil, on: monday) == nil)
        #expect(TrainingDays.none.effectiveTarget(base, on: monday) == base)
    }

    @Test func `merging a backup keeps one live schedule per day`() throws {
        let f = try Fixture()
        try f.trainingDays.setSchedule(weekdays: [2], boostPercent: 10, effectiveFrom: monday)
        try f.trainingDays.setTraining(true, on: monday.next)
        let export = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()

        // Another phone set its own schedule for the same day.
        let other = try Fixture()
        try other.trainingDays.setSchedule(weekdays: [3], boostPercent: 20, effectiveFrom: monday)
        try DataPortability(other.db, clock: other.clock.appClock).importJSON(export, mode: .merge)
        #expect(try other.trainingDays.scheduleHistory().count == 1)
        #expect(try other.trainingDays.schedule(on: monday)?.weekdays == [3]) // local wins the clash
        #expect(try other.trainingDays.overrides(in: monday ... monday.next) == [monday.next: true])
    }
}
