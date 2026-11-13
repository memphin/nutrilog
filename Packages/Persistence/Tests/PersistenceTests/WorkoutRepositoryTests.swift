import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

private let watch = HealthSource(name: "Apple Watch", bundleIdentifier: "com.apple.health.W1", productType: "Watch7,1")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// A workout on `dayString` at `hour`:00 UTC for `minutes`.
private func workout(
    _ id: String, _ kind: WorkoutKind, _ dayString: String, hour: Int = 18, minutes: Double = 60, kcal: Double? = nil,
    km: Double? = nil,
) -> HealthWorkout {
    let start = day(dayString).startDate(calendar: utc).addingTimeInterval(TimeInterval(hour * 3600))
    return HealthWorkout(
        id: id, day: day(dayString), activityType: kind.rawValue, start: start, end: start.addingTimeInterval(minutes * 60),
        activeKcal: kcal, distanceM: km.map { $0 * 1000 }, source: watch,
    )
}

/// [00:00 of the first day, 00:00 after the last) in UTC, as a sync reads it.
private func interval(_ first: String, _ last: String) -> DateInterval {
    DateInterval(start: day(first).startDate(calendar: utc), end: day(last).next.startDate(calendar: utc))
}

struct WorkoutMigrationTests {
    @Test func `migration 018 adds the workout table and keeps training days`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        let index = try #require(Migrator.migrations.firstIndex(of: "018_health_workout"))
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
            INSERT INTO training_day (day, is_training, created_at, updated_at) VALUES ('2026-11-09', 1, ?, ?)
            """, arguments: [stamp, stamp])
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        let columns = try queue.read { db in try db.columns(in: "health_workout").map(\.name) }
        for column in [
            "id", "day", "activity_type", "start_at", "end_at", "duration_sec", "active_kcal", "distance_m", "source_name",
            "source_bundle_id", "source_product_type", "created_at", "updated_at", "deleted_at", "revision",
        ] {
            #expect(columns.contains(column), "missing health_workout.\(column)")
        }
        // The day switched on by hand is still a training day; no workout decides anything yet.
        let days = try TrainingDayRepository(db).trainingDays(in: day("2026-11-01") ... day("2026-11-30"))
        #expect(days.isTraining(day("2026-11-09")))
        #expect(days.workoutDays.isEmpty)
        #expect(try WorkoutRepository(db).rules() == .none)
        #expect(DataPortability.tables.contains("health_workout"))
    }
}

struct WorkoutNameMigrationTests {
    @Test func `migration 019 marks every stored workout as not custom and adds the names table`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        let index = try #require(Migrator.migrations.firstIndex(of: "019_workout_names"))
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
            INSERT INTO health_workout (id, day, activity_type, start_at, end_at, duration_sec, created_at, updated_at)
            VALUES ('run', '2026-11-09', 37, '2026-11-09T18:00:00.000Z', '2026-11-09T19:00:00.000Z', 3600, ?, ?)
            """, arguments: [stamp, stamp])
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        let run = try #require(try WorkoutRepository(db).workouts(in: day("2026-11-09") ... day("2026-11-09")).first)
        #expect(!run.isCustomWorkout)
        #expect(run.name == nil)
        let columns = try queue.read { db in try db.columns(in: "workout_name").map(\.name) }
        #expect(Set(columns) == ["workout_id", "name", "created_at", "updated_at", "deleted_at", "revision"])
        #expect(DataPortability.tables.contains("workout_name"))
    }
}

struct WorkoutRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `workouts are stored and read back, oldest first`() throws {
        let f = try Fixture()
        let run = workout("run", .running, "2026-11-10", hour: 7, minutes: 41.5, kcal: 480.5, km: 6.8)
        let lift = workout("lift", .strength, "2026-11-09", kcal: 410)
        #expect(try f.workouts.reconcile([run, lift], in: interval("2026-11-09", "2026-11-10")) == 2)
        let stored = try f.workouts.workouts(in: monday ... monday.next)
        #expect(stored.map(\.id) == ["lift", "run"])
        #expect(stored[1].kind == .running)
        #expect(stored[1].durationSec == run.durationSec)
        #expect(stored[1].activeKcal == 480.5)
        #expect(stored[1].distanceM == 6800)
        #expect(stored[1].source == watch)
        #expect(abs(stored[1].start.timeIntervalSince(run.start)) < 0.002)
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.id) == ["lift"])
        #expect(try f.workouts.latestWorkout(in: monday ... monday.next)?.id == "run")
        #expect(try f.workouts.latestWorkout(in: monday.adding(days: 5) ... monday.adding(days: 6)) == nil)
    }

    @Test func `reading the same workouts again changes nothing`() throws {
        let f = try Fixture()
        let workouts = [workout("lift", .strength, "2026-11-09", kcal: 410), workout("walk", .walking, "2026-11-09", hour: 12, km: 3.1)]
        try f.workouts.reconcile(workouts, in: interval("2026-11-09", "2026-11-09"))
        f.clock.advance(60)
        #expect(try f.workouts.reconcile(workouts, in: interval("2026-11-09", "2026-11-09")) == 0)
        let rows = try f.db.reader.read { db in try WorkoutRecord.fetchAll(db) }
        #expect(rows.allSatisfy { $0.revision == 1 && $0.updatedAt == $0.createdAt })
    }

    @Test func `a changed workout is updated and one gone from Health is deleted`() throws {
        let f = try Fixture()
        try f.workouts.reconcile(
            [workout("lift", .strength, "2026-11-09", kcal: 400), workout("walk", .walking, "2026-11-09", hour: 12)],
            in: interval("2026-11-09", "2026-11-09"),
        )
        f.clock.advance(60)
        // The watch finished computing the energy; the walk was deleted in Health.
        #expect(try f.workouts
            .reconcile([workout("lift", .strength, "2026-11-09", kcal: 425)], in: interval("2026-11-09", "2026-11-09")) == 2)
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.activeKcal) == [425])
        let rows = try f.db.reader.read { db in try WorkoutRecord.order(WorkoutRecord.Columns.id).fetchAll(db) }
        #expect(rows.map(\.id) == ["lift", "walk"])
        #expect(rows[0].revision == 2 && rows[0].updatedAt > rows[0].createdAt)
        #expect(rows[1].deletedAt != nil && rows[1].revision == 2) // a tombstone
        // Back in Health (restored from a backup of the watch, say): the same row lives again.
        f.clock.advance(60)
        let both = [workout("lift", .strength, "2026-11-09", kcal: 425), workout("walk", .walking, "2026-11-09", hour: 12)]
        #expect(try f.workouts.reconcile(both, in: interval("2026-11-09", "2026-11-09")) == 1)
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.id) == ["walk", "lift"])
    }

    @Test func `workouts outside the days read are left alone`() throws {
        let f = try Fixture()
        try f.workouts.reconcile([workout("old", .strength, "2026-08-01")], in: interval("2026-08-01", "2026-08-01"))
        // A later sync reads only November and finds nothing: August stays.
        #expect(try f.workouts.reconcile([], in: interval("2026-11-01", "2026-11-30")) == 0)
        #expect(try f.workouts.workouts(in: day("2026-08-01") ... day("2026-11-30")).map(\.id) == ["old"])
    }

    @Test func `a custom workout is stored as one, and a sync that finds the marker updates the row`() throws {
        let f = try Fixture()
        var run = workout("run", .running, "2026-11-09")
        try f.workouts.reconcile([run], in: interval("2026-11-09", "2026-11-09"))
        run.isCustomWorkout = true
        #expect(try f.workouts.reconcile([run], in: interval("2026-11-09", "2026-11-09")) == 1)
        let stored = try #require(try f.workouts.workouts(in: monday ... monday).first)
        #expect(stored.isCustomWorkout)
        #expect(stored.title == "Refereeing")
    }

    @Test func `kinds list what Apple Health has, each once`() throws {
        let f = try Fixture()
        #expect(try f.workouts.kinds().isEmpty)
        try f.workouts.reconcile(
            [
                workout("a", .strength, "2026-11-09"), workout("b", .strength, "2026-11-10"), workout("c", .walking, "2026-11-10", hour: 8),
                HealthWorkout(
                    id: "d", day: monday, activityType: 2, start: workout("x", .other, "2026-11-09", hour: 9).start,
                    end: workout("x", .other, "2026-11-09", hour: 10).start, source: watch,
                ), // archery: no kind of its own
            ],
            in: interval("2026-11-09", "2026-11-10"),
        )
        #expect(try f.workouts.kinds() == [.other, .strength, .walking]) // by name
    }

    @Test func `observing workouts follows a sync`() async throws {
        let f = try Fixture()
        var iterator = f.workouts.observeWorkouts(in: monday ... monday).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        try f.workouts.reconcile([workout("lift", .strength, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        #expect(try await iterator.next()?.map(\.id) == ["lift"])
    }
}

struct WorkoutNameRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `a name is kept, changed and cleared`() throws {
        let f = try Fixture()
        try f.workouts.reconcile([workout("run", .running, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        try f.workouts.setName("  Cup final ", for: "run")
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.title) == ["Cup final"])
        f.clock.advance(60)
        try f.workouts.setName("Cup final", for: "run") // the same name: no change
        var row = try #require(try f.db.reader.read { db in try WorkoutNameRecord.fetchOne(db, key: "run") })
        #expect(row.revision == 1)
        try f.workouts.setName("Derby", for: "run")
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.title) == ["Derby"])
        // Cleared: back to the kind's name, the row a tombstone.
        try f.workouts.setName(" ", for: "run")
        #expect(try f.workouts.workouts(in: monday ... monday).map(\.title) == ["Running"])
        row = try #require(try f.db.reader.read { db in try WorkoutNameRecord.fetchOne(db, key: "run") })
        #expect(row.deletedAt != nil && row.revision == 3)
        // Named again: the same row lives again.
        try f.workouts.setName("Final", for: "run")
        row = try #require(try f.db.reader.read { db in try WorkoutNameRecord.fetchOne(db, key: "run") })
        #expect(row.deletedAt == nil && row.name == "Final" && row.revision == 4)
    }

    @Test func `a name survives syncs and leaves training alone`() throws {
        let f = try Fixture()
        try f.workouts.startRulesIfNeeded(from: day("2026-11-01"))
        try f.workouts.reconcile([workout("run", .running, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        try f.workouts.setName("Refereeing", for: "run")
        try f.workouts.reconcile([workout("run", .running, "2026-11-09", kcal: 500)], in: interval("2026-11-09", "2026-11-09"))
        let stored = try f.workouts.workouts(in: monday ... monday)
        #expect(stored.map(\.title) == ["Refereeing"])
        #expect(stored.map(\.activeKcal) == [500])
        #expect(try f.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))
        #expect(try f.workouts.latestWorkout(in: monday ... monday)?.name == "Refereeing")
    }

    @Test func `observing workouts follows a name`() async throws {
        let f = try Fixture()
        try f.workouts.reconcile([workout("run", .running, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        var iterator = f.workouts.observeWorkouts(in: monday ... monday).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.title) == ["Running"])
        try f.workouts.setName("Refereeing", for: "run")
        #expect(try await iterator.next()?.map(\.title) == ["Refereeing"])
    }

    @Test func `names survive an export and a restore`() throws {
        let f = try Fixture()
        try f.workouts.reconcile([workout("run", .running, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        try f.workouts.setName("Cup final", for: "run")
        let export = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let restored = try Fixture()
        try DataPortability(restored.db, clock: restored.clock.appClock).importJSON(export, mode: .replace)
        #expect(try restored.workouts.workouts(in: monday ... monday).map(\.title) == ["Cup final"])
    }
}

struct TrainingRulesRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `rules start once, with walking left out`() throws {
        let f = try Fixture()
        #expect(try f.workouts.rules() == .none)
        try f.workouts.startRulesIfNeeded(from: monday)
        try f.workouts.startRulesIfNeeded(from: monday.adding(days: 3)) // already started: no change
        let rules = try f.workouts.rules()
        #expect(rules == TrainingRules([monday: [.walking]]))
        #expect(rules.decidesTrainingDays(on: monday))
        #expect(!rules.decidesTrainingDays(on: monday.previous))
        // Kept as a setting, so it is exported and backed up.
        let raw = try f.profiles.setting(WorkoutRepository.rulesSettingKey, as: [TrainingRulesEntry].self)
        #expect(raw == [TrainingRulesEntry(from: monday, excluded: [52])])
    }

    @Test func `a change applies from its day; the same day replaces; the same choice is no change`() throws {
        let f = try Fixture()
        try f.workouts.startRulesIfNeeded(from: monday)
        let wednesday = monday.adding(days: 2)
        try f.workouts.setExcluded([.walking, .yoga], from: wednesday)
        #expect(try f.workouts.rules() == TrainingRules([monday: [.walking], wednesday: [.walking, .yoga]]))
        try f.workouts.setExcluded([.yoga], from: wednesday)
        #expect(try f.workouts.rules() == TrainingRules([monday: [.walking], wednesday: [.yoga]]))
        // Back to what Monday's choice says: Wednesday's entry goes.
        try f.workouts.setExcluded([.walking], from: wednesday)
        #expect(try f.workouts.rules() == TrainingRules([monday: [.walking]]))
        // The same choice again on a later day adds nothing.
        try f.workouts.setExcluded([.walking], from: monday.adding(days: 5))
        #expect(try f.workouts.rules() == TrainingRules([monday: [.walking]]))
    }

    @Test func `a first choice in Settings starts the rules`() throws {
        let f = try Fixture()
        let rules = try f.workouts.setExcluded([], from: monday)
        #expect(rules == TrainingRules([monday: []]))
        #expect(rules.countsAsTraining(.walking, on: monday))
    }

    @Test func `observing rules follows a change`() async throws {
        let f = try Fixture()
        var iterator = f.workouts.observeRules().makeAsyncIterator()
        #expect(try await iterator.next() == TrainingRules.none)
        try f.workouts.setExcluded([.walking, .hiking], from: monday)
        #expect(try await iterator.next()?.currentExcluded == [.walking, .hiking])
    }
}

/// Workouts and training days together: a training workout makes its day a training day.
struct WorkoutTrainingDayTests {
    let monday = day("2026-11-09")

    func fixture(_ workouts: [HealthWorkout], rulesFrom: LocalDay?) throws -> Fixture {
        let f = try Fixture()
        if let rulesFrom {
            try f.workouts.startRulesIfNeeded(from: rulesFrom)
        }
        try f.workouts.reconcile(workouts, in: interval("2026-11-01", "2026-11-30"))
        return f
    }

    @Test func `a training workout makes its day a training day, a walk doesn't`() throws {
        let f = try fixture(
            [workout("lift", .strength, "2026-11-09"), workout("walk", .walking, "2026-11-10")], rulesFrom: day("2026-11-01"),
        )
        let days = try f.trainingDays.trainingDays(in: monday ... monday.adding(days: 6))
        #expect(days.workoutDays == [monday])
        #expect(days.isTraining(monday))
        #expect(!days.isTraining(monday.next))
        #expect(days.boost(on: monday) == 10)
        // The day's target is boosted like any training day's.
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-11-01"), kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 70), origin: .manual,
        ))
        #expect(try f.trainingDays.effectiveTarget(on: monday)?.kcal == 2200)
        #expect(try f.trainingDays.effectiveTarget(on: monday.next)?.kcal == 2000)
    }

    @Test func `workouts before the rules started leave their days as they were`() throws {
        let f = try fixture([workout("old", .strength, "2026-11-08"), workout("new", .strength, "2026-11-09")], rulesFrom: monday)
        let days = try f.trainingDays.trainingDays(in: day("2026-11-01") ... day("2026-11-30"))
        #expect(days.workoutDays == [monday])
        // And without any rules, no day at all.
        let none = try fixture([workout("new", .strength, "2026-11-09")], rulesFrom: nil)
        #expect(try none.trainingDays.trainingDays(in: monday ... monday) == .none)
    }

    @Test func `only workouts of the days asked for are counted`() throws {
        let f = try fixture([workout("a", .strength, "2026-11-09"), workout("b", .strength, "2026-11-20")], rulesFrom: day("2026-11-01"))
        #expect(try f.trainingDays.trainingDays(in: monday ... monday.adding(days: 6)).workoutDays == [monday])
    }

    @Test func `switching a workout day off is kept, and back on follows the workout again`() throws {
        let f = try fixture([workout("lift", .strength, "2026-11-09")], rulesFrom: day("2026-11-01"))
        // A workout day is a training day by itself: switching it off is an override…
        #expect(try f.trainingDays.toggleTraining(on: monday) == false)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [monday: false])
        #expect(try !f.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))
        // …that a later sync of the same workout doesn't undo…
        try f.workouts.reconcile([workout("lift", .strength, "2026-11-09", kcal: 400)], in: interval("2026-11-09", "2026-11-09"))
        #expect(try !f.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))
        // …and switching it back on needs no override.
        #expect(try f.trainingDays.toggleTraining(on: monday) == true)
        #expect(try f.trainingDays.overrides(in: monday ... monday) == [:])
    }

    @Test func `a workout deleted in Health or a kind switched off ends the training day`() throws {
        let f = try fixture([workout("yoga", .yoga, "2026-11-09")], rulesFrom: day("2026-11-01"))
        #expect(try f.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))
        // Yoga no longer counts from Tuesday: Monday keeps its status, a later yoga day isn't one.
        try f.workouts.setExcluded([.walking, .yoga], from: monday.next)
        try f.workouts.reconcile(
            [workout("yoga", .yoga, "2026-11-09"), workout("yoga-2", .yoga, "2026-11-11")], in: interval("2026-11-01", "2026-11-30"),
        )
        let days = try f.trainingDays.trainingDays(in: monday ... monday.adding(days: 6))
        #expect(days.workoutDays == [monday])
        // Deleted in Health: gone here too.
        try f.workouts.reconcile([], in: interval("2026-11-01", "2026-11-30"))
        #expect(try f.trainingDays.trainingDays(in: monday ... monday.adding(days: 6)) == .none)
    }

    @Test func `observing training days follows the workouts and the rules`() async throws {
        let f = try Fixture()
        var iterator = f.trainingDays.observeTrainingDays(in: monday ... monday.adding(days: 6)).makeAsyncIterator()
        #expect(try await iterator.next() == TrainingDays.none)
        try f.workouts.startRulesIfNeeded(from: monday)
        try f.workouts.reconcile([workout("lift", .strength, "2026-11-09")], in: interval("2026-11-09", "2026-11-09"))
        #expect(try await iterator.next()?.isTraining(monday) == true)
        try f.workouts.setExcluded([.walking, .strength], from: monday)
        #expect(try await iterator.next()?.isTraining(monday) == false)
    }

    @Test func `workouts and rules survive an export and a restore`() throws {
        let f = try fixture([workout("lift", .strength, "2026-11-09", kcal: 410)], rulesFrom: day("2026-11-01"))
        let export = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let restored = try Fixture()
        try DataPortability(restored.db, clock: restored.clock.appClock).importJSON(export, mode: .replace)
        #expect(try restored.workouts.workouts(in: monday ... monday).map(\.activeKcal) == [410])
        #expect(try restored.trainingDays.trainingDays(in: monday ... monday).isTraining(monday))
    }
}
