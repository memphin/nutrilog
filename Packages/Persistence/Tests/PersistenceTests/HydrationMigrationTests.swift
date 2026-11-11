import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Migrations 013 (hydration columns and backfills) and 014 (caffeine drink volumes), and the new record properties.
struct HydrationMigrationTests {
    static let stamp = "2026-01-01T00:00:00.000Z"

    /// A database migrated up to 012, as the app had it before hydration tracking.
    static func preHydrationDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Migrator.make(deviceCalendar: .gregorian).migrate(queue, upTo: "012_food_merged_into")
        return queue
    }

    static func food(_ db: Database, _ id: String, liquid: Bool, fat: Double) throws {
        try db.execute(
            sql: """
            INSERT INTO food (id, name, source, kcal_100, protein_g_100, carbs_g_100, fat_g_100, is_liquid, created_at, updated_at)
            VALUES (?, ?, 'custom', 100, 1, 1, ?, ?, ?, ?)
            """,
            arguments: [id, id.capitalized, fat, liquid, stamp, stamp],
        )
    }

    static func diary(_ db: Database, _ id: String, foodID: String?, grams: Double, quickAdd: Bool = false) throws {
        try db.execute(
            sql: """
            INSERT INTO diary_entry (id, day, meal_slot_id, food_id, display_name, grams, is_quick_add, kcal, protein_g,
                carbs_g, fat_g, logged_at, created_at, updated_at)
            VALUES (?, '2026-01-01', 'breakfast', ?, ?, ?, ?, 100, 1, 1, 1, ?, ?, ?)
            """,
            arguments: [id, foodID, id.capitalized, grams, quickAdd, stamp, stamp, stamp],
        )
    }

    static func caffeine(_ db: Database, _ id: String, drinkID: String?) throws {
        try db.execute(
            sql: """
            INSERT INTO caffeine_entry (id, day, logged_at, mg, drink_id, created_at, updated_at)
            VALUES (?, '2026-01-01', ?, 64, ?, ?, ?)
            """,
            arguments: [id, stamp, drinkID, stamp, stamp],
        )
    }

    static func fluid(_ queue: DatabaseQueue, _ id: String) throws -> Double? {
        try queue.read { try Double.fetchOne($0, sql: "SELECT fluid_ml FROM diary_entry WHERE id = ?", arguments: [id]) }
    }

    @Test func `backfills diary fluid for liquid foods`() throws {
        let queue = try Self.preHydrationDatabase()
        try queue.write { db in
            try Self.food(db, "milk", liquid: true, fat: 2.8)
            try Self.food(db, "olive_oil", liquid: true, fat: 100)
            try Self.food(db, "oats", liquid: false, fat: 7)
            try Self.food(db, "gone", liquid: true, fat: 0)
            try Self.diary(db, "milk_entry", foodID: "milk", grams: 250)
            try Self.diary(db, "oil_entry", foodID: "olive_oil", grams: 15)
            try Self.diary(db, "oats_entry", foodID: "oats", grams: 50)
            try Self.diary(db, "quick_entry", foodID: nil, grams: 0, quickAdd: true)
            try Self.diary(db, "orphan_entry", foodID: "gone", grams: 330)
            // The food row is gone: `diary_entry.food_id` is `ON DELETE SET NULL`.
            try db.execute(sql: "DELETE FROM food WHERE id = 'gone'")
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)

        #expect(try Self.fluid(queue, "milk_entry") == 250)
        #expect(try Self.fluid(queue, "oil_entry") == nil)
        #expect(try Self.fluid(queue, "oats_entry") == nil)
        #expect(try Self.fluid(queue, "quick_entry") == nil)
        #expect(try Self.fluid(queue, "orphan_entry") == nil)
        #expect(try DiaryRepository(db).entry(id: "milk_entry")?.fluidMl == 250)
        #expect(try FoodRepository(db).food(id: "milk")?.countsAsFluid == nil)
    }

    @Test func `goal mode is fixed only for a custom goal`() throws {
        for (goal, mode) in [(2500.0, HydrationGoalMode.weight), (3000.0, .fixed)] {
            let queue = try Self.preHydrationDatabase()
            try queue.write { db in
                try db.execute(sql: "UPDATE profile SET water_goal_ml = ?", arguments: [goal])
            }
            let db = try AppDatabase(queue)
            let profile = try ProfileRepository(db).profile()
            #expect(profile.waterGoalMode == mode, "goal \(goal)")
            #expect(profile.waterGoalMl == goal)
        }
    }

    @Test func `new databases default to the weight based goal`() throws {
        let f = try Fixture()
        #expect(try f.profiles.profile().waterGoalMode == .weight)
    }

    @Test func `backfills caffeine ml from the preset`() throws {
        let queue = try Self.preHydrationDatabase()
        try queue.write { db in
            try Self.caffeine(db, "espresso_entry", drinkID: "espresso")
            try Self.caffeine(db, "cola_entry", drinkID: "cola")
            try Self.caffeine(db, "custom_entry", drinkID: nil)
            try Self.caffeine(db, "unknown_entry", drinkID: "retired_drink")
        }
        _ = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)

        let entries = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: CaffeineEntry.fetchAll(db).map { ($0.id, $0.ml) })
        }
        #expect(entries["espresso_entry"] == .some(30))
        #expect(entries["cola_entry"] == .some(330))
        #expect(entries["custom_entry"] == .some(nil))
        #expect(entries["unknown_entry"] == .some(nil))
    }

    @Test func `records round trip the new columns`() throws {
        let f = try Fixture()

        // Food override.
        var soup = try f.makeFood("Soup")
        soup.countsAsFluid = true
        try f.foods.save(FoodDetail(food: soup, servings: [], barcodes: []))
        #expect(try f.foods.food(id: soup.id)?.countsAsFluid == true)
        soup.countsAsFluid = false
        try f.foods.save(FoodDetail(food: soup, servings: [], barcodes: []))
        #expect(try f.foods.food(id: soup.id)?.countsAsFluid == false)

        // Diary fluid snapshot.
        let logged = try f.diary.logQuickAdd(
            name: "Broth",
            nutrients: Nutrients(kcal: 20, proteinG: 1, carbsG: 1, fatG: 0),
            slotID: "lunch",
            day: day("2026-11-09"),
        )
        try f.db.writer.write { db in
            var entry = try #require(try DiaryEntry.fetchOne(db, key: logged.id))
            entry.fluidMl = 300
            try entry.update(db)
        }
        #expect(try f.diary.entry(id: logged.id)?.fluidMl == 300)

        // Profile goal mode.
        var profile = try f.profiles.profile()
        profile.waterGoalMode = .fixed
        try f.profiles.save(profile)
        #expect(try f.profiles.profile().waterGoalMode == .fixed)
        #expect(try f.db.reader.read { try String.fetchOne($0, sql: "SELECT water_goal_mode FROM profile") } == "fixed")

        // Caffeine volume.
        let drink = try f.caffeine.add(mg: 64, day: day("2026-11-09"), drinkID: "espresso", name: "Espresso")
        try f.db.writer.write { db in
            var entry = try #require(try CaffeineEntry.fetchOne(db, key: drink.id))
            entry.ml = 30
            try entry.update(db)
        }
        #expect(try f.db.reader.read { try CaffeineEntry.fetchOne($0, key: drink.id)?.ml } == 30)

        // Wake-up time, from the Health values through the sleep import's upsert.
        let metrics = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        let woke = Date(timeIntervalSince1970: 1_794_200_000 - 3 * 3600) // whole seconds, like the test clock
        let night = DailyHealthMetrics(day: day("2026-11-09"), sleepAsleepMin: 450, wokeAt: woke)
        #expect(try metrics.upsert([night]) == 1)
        let row = try #require(try metrics.metrics(on: day("2026-11-09")))
        #expect(row.wokeAt == woke)
        #expect(row.metrics == night)
        #expect(try f.db.reader.read { try String.fetchOne($0, sql: "SELECT woke_at FROM daily_metrics") }
            == Timestamp.string(woke))
        #expect(try metrics.upsert([night]) == 0) // unchanged refresh
    }

    @Test func `refreshing an unchanged wake up time with sub millisecond precision is no change`() throws {
        let f = try Fixture()
        let metrics = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        // Health sample ends carry more precision than the stored millisecond timestamps.
        let woke = Date(timeIntervalSinceReferenceDate: 784_000_000.123456)
        let night = DailyHealthMetrics(day: day("2026-11-09"), sleepAsleepMin: 450, wokeAt: woke)
        #expect(try metrics.upsert([night]) == 1)
        f.clock.advance(60)
        #expect(try metrics.upsert([night]) == 0)
        #expect(try metrics.metrics(on: day("2026-11-09"))?.revision == 1)

        // A later wake-up time is a change.
        var later = night
        later.wokeAt = woke.addingTimeInterval(60)
        #expect(try metrics.upsert([later]) == 1)
        let row = try #require(try metrics.metrics(on: day("2026-11-09")))
        #expect(row.revision == 2)
        #expect(try abs(#require(row.wokeAt).timeIntervalSince(woke) - 60) < 0.002)
    }

    @Test func `fluid index exists for active drinks`() throws {
        let f = try Fixture()
        let sql = try f.db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_diary_entry_fluid'")
        }
        #expect(sql?.contains("fluid_ml > 0 AND deleted_at IS NULL") == true)
    }
}
