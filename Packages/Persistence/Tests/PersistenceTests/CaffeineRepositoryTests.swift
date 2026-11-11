import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct CaffeineMigrationTests {
    @Test func `migration 010 adds the caffeine table and columns and keeps existing rows`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        for name in Migrator.migrations.prefix(9) {
            old.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
        }
        try old.migrate(queue)
        let stamp = "2026-01-01T00:00:00.000Z"
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO food (id, name, source, kcal_100, protein_g_100, carbs_g_100, fat_g_100, sodium_mg_100, created_at, updated_at)
            VALUES ('coffee', 'Coffee', 'custom', 2, 0.3, 0, 0, 5, ?, ?)
            """, arguments: [stamp, stamp])
            try db.execute(sql: """
            INSERT INTO diary_entry (id, day, meal_slot_id, food_id, display_name, grams, kcal, protein_g, carbs_g, fat_g,
                logged_at, created_at, updated_at)
            VALUES ('e1', '2026-01-01', 'breakfast', 'coffee', 'Coffee', 250, 5, 0.75, 0, 0, ?, ?, ?)
            """, arguments: [stamp, stamp, stamp])
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        #expect(Migrator.migrations.contains("010_caffeine"))

        let (tables, foodColumns, diaryColumns, caffeineColumns) = try queue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"),
                db.columns(in: "food").map(\.name),
                db.columns(in: "diary_entry").map(\.name),
                db.columns(in: "caffeine_entry").map(\.name),
            )
        }
        #expect(tables.contains("caffeine_entry"))
        #expect(foodColumns.contains("caffeine_mg_100"))
        #expect(diaryColumns.contains("caffeine_mg"))
        for column in ["id", "day", "logged_at", "mg", "drink_id", "name", "created_at", "updated_at", "deleted_at", "revision"] {
            #expect(caffeineColumns.contains(column), "missing caffeine_entry.\(column)")
        }
        let coffee = try #require(try FoodRepository(db).food(id: "coffee"))
        #expect(coffee.caffeineMg100 == nil)
        #expect(coffee.sodiumMg100 == 5)
        let entry = try #require(try DiaryRepository(db).entry(id: "e1"))
        #expect(entry.caffeineMg == nil)
        #expect(entry.kcal == 5)
        #expect(DataPortability.tables.contains("caffeine_entry"))
    }

    @Test func `mg must be positive in the table too`() throws {
        let f = try Fixture()
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO caffeine_entry (id, day, logged_at, mg, created_at, updated_at)
                VALUES ('x', '2026-11-09', '2026-11-09T08:00:00.000Z', 0, '2026-11-09T08:00:00.000Z', '2026-11-09T08:00:00.000Z')
                """)
            }
        }
    }
}

struct CaffeineRepositoryTests {
    let d = day("2026-11-09")

    @Test func `add validates the amount and cleans the name`() throws {
        let f = try Fixture()
        for bad in [0.0, -5, .nan, .infinity] {
            #expect(throws: PersistenceError.validation("amount must be greater than zero")) {
                try f.caffeine.add(mg: bad, day: d)
            }
        }
        let espresso = try f.caffeine.add(mg: 64, day: d, drinkID: "espresso", name: " Espresso ")
        #expect(espresso.name == "Espresso")
        #expect(espresso.drinkID == "espresso")
        #expect(espresso.loggedAt == f.clock.now)
        #expect(espresso.revision == 1)
        let custom = try f.caffeine.add(mg: 120, day: d, name: "   ")
        #expect(custom.name == nil)
        #expect(custom.drinkID == nil)
        #expect(try f.caffeine.entry(id: espresso.id) == espresso)
    }

    @Test func `preset stores serving ml`() throws {
        let f = try Fixture()
        let espresso = try f.caffeine.add(mg: 64, day: d, drinkID: "espresso", name: "Espresso")
        #expect(espresso.ml == 30)
        #expect(try f.caffeine.entry(id: espresso.id)?.ml == 30)
        let cola = try f.caffeine.add(mg: 33, day: d, drinkID: "cola", name: "Cola")
        #expect(try f.caffeine.entry(id: cola.id)?.ml == 330)
        // A given volume wins over the preset's serving.
        let large = try f.caffeine.add(mg: 66, day: d, drinkID: "cola", name: "Cola", ml: 500)
        #expect(try f.caffeine.entry(id: large.id)?.ml == 500)
    }

    @Test func `custom amount stores given ml`() throws {
        let f = try Fixture()
        let custom = try f.caffeine.add(mg: 80, day: d, name: "Cold brew", ml: 250)
        #expect(custom.ml == 250)
        #expect(try f.caffeine.entry(id: custom.id)?.ml == 250)
        for bad in [0.0, -5, .nan, .infinity] {
            #expect(throws: PersistenceError.validation("amount must be greater than zero")) {
                try f.caffeine.add(mg: 80, day: d, ml: bad)
            }
        }
    }

    @Test func `custom without ml is nil`() throws {
        let f = try Fixture()
        let custom = try f.caffeine.add(mg: 80, day: d)
        #expect(custom.ml == nil)
        #expect(try f.caffeine.entry(id: custom.id)?.ml == nil)
        // An id no preset has gets no volume either.
        let unknown = try f.caffeine.add(mg: 80, day: d, drinkID: "retired_drink")
        #expect(try f.caffeine.entry(id: unknown.id)?.ml == nil)
    }

    @Test func `entries are listed per day and per range, oldest first`() throws {
        let f = try Fixture()
        let now = f.clock.now
        let late = try f.caffeine.add(mg: 95, day: d, loggedAt: now.addingTimeInterval(3600))
        let early = try f.caffeine.add(mg: 64, day: d, loggedAt: now)
        let yesterday = try f.caffeine.add(mg: 47, day: d.previous, loggedAt: now.addingTimeInterval(-86400))
        try f.caffeine.add(mg: 30, day: d.adding(days: 5))
        #expect(try f.caffeine.entries(for: d).map(\.id) == [early.id, late.id])
        #expect(try f.caffeine.entries(in: d.previous ... d).map(\.id) == [yesterday.id, early.id, late.id])
        #expect(try f.caffeine.entries(in: d.adding(days: 1) ... d.adding(days: 4)).isEmpty)
    }

    @Test func `update changes amount and time, and the day only when given`() throws {
        let f = try Fixture()
        let entry = try f.caffeine.add(mg: 64, day: d)
        f.clock.advance(60)
        let later = f.clock.now.addingTimeInterval(3600)
        let updated = try f.caffeine.update(id: entry.id, mg: 128, loggedAt: later)
        #expect(updated.mg == 128)
        #expect(updated.loggedAt == later)
        #expect(updated.day == d)
        #expect(updated.revision == 2)
        #expect(updated.updatedAt == f.clock.now)
        #expect(try f.caffeine.entry(id: entry.id) == updated)

        let moved = try f.caffeine.update(id: entry.id, mg: 128, loggedAt: later, day: d.next)
        #expect(moved.day == d.next)
        #expect(try f.caffeine.entries(for: d).isEmpty)

        #expect(throws: PersistenceError.validation("amount must be greater than zero")) {
            try f.caffeine.update(id: entry.id, mg: 0, loggedAt: later)
        }
        #expect(throws: PersistenceError.notFound("missing")) {
            try f.caffeine.update(id: "missing", mg: 10, loggedAt: later)
        }
        try f.caffeine.softDelete(ids: [entry.id])
        #expect(throws: PersistenceError.notFound(entry.id)) {
            try f.caffeine.update(id: entry.id, mg: 10, loggedAt: later)
        }
    }

    @Test func `soft delete and restore, without touching Apple Health`() throws {
        let f = try Fixture()
        let a = try f.caffeine.add(mg: 64, day: d)
        let b = try f.caffeine.add(mg: 95, day: d)
        f.clock.advance(10)
        try f.caffeine.softDelete(ids: [a.id, "unknown"])
        #expect(try f.caffeine.entries(for: d).map(\.id) == [b.id])
        let deleted = try #require(try f.caffeine.entry(id: a.id))
        #expect(deleted.deletedAt == f.clock.now)
        #expect(deleted.revision == 2)
        try f.caffeine.softDelete(ids: [a.id]) // already deleted: no change
        #expect(try f.caffeine.entry(id: a.id)?.revision == 2)

        try f.caffeine.restore(ids: [a.id, b.id]) // b is active: untouched
        #expect(Set(try f.caffeine.entries(for: d).map(\.id)) == [a.id, b.id])
        #expect(try f.caffeine.entry(id: a.id)?.deletedAt == nil)
        #expect(try f.caffeine.entry(id: a.id)?.revision == 3)
        #expect(try f.caffeine.entry(id: b.id)?.revision == 1)
        #expect(try f.healthLinks.pending().isEmpty)
    }

    @Test func `observing entries follows every change`() async throws {
        let f = try Fixture()
        var iterator = f.caffeine.observeEntries(in: d.previous ... d).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let entry = try f.caffeine.add(mg: 64, day: d)
        #expect(try await iterator.next()?.map(\.id) == [entry.id])
        try f.caffeine.softDelete(ids: [entry.id])
        #expect(try await iterator.next() == [])
        try f.caffeine.restore(ids: [entry.id])
        #expect(try await iterator.next()?.map(\.mg) == [64])
    }
}

struct DiaryCaffeineTests {
    let d = day("2026-11-09")

    func coffee(_ f: Fixture, caffeinePer100: Double? = 40) throws -> Food {
        let food = Food(
            name: "Filter coffee",
            per100: Nutrients(kcal: 2, proteinG: 0.3, carbsG: 0, fatG: 0, sodiumMg: 2, caffeineMg: caffeinePer100),
            isLiquid: true,
        )
        return try f.foods.save(FoodDetail(food: food)).food
    }

    @Test func `caffeine is stored on foods and snapshotted on diary entries`() throws {
        let f = try Fixture()
        let food = try coffee(f)
        #expect(try f.foods.food(id: food.id)?.caffeineMg100 == 40)
        #expect(try f.foods.food(id: food.id)?.per100.caffeineMg == 40)

        let entry = try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d)
        #expect(entry.caffeineMg == 100)
        #expect(try f.diary.entry(id: entry.id)?.nutrients.caffeineMg == 100)

        // Editing the food later doesn't change history; resizing scales the snapshot.
        var detail = try #require(try f.foods.detail(id: food.id))
        detail.food.caffeineMg100 = 80
        try f.foods.save(detail)
        try f.diary.updateQuantity(entryID: entry.id, quantity: .base(125))
        #expect(try f.diary.entry(id: entry.id)?.caffeineMg == 50)

        #expect(try f.diary.totals(for: d).caffeineMg == 50)
        #expect(try f.diary.daySummaries(in: d ... d).first?.totals.caffeineMg == 50)
    }

    @Test func `the dose query returns active entries with caffeine only`() throws {
        let f = try Fixture()
        let food = try coffee(f)
        let decaf = try coffee(f, caffeinePer100: 0)
        let unknown = try coffee(f, caffeinePer100: nil)
        let morning = try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d)
        let morningTime = f.clock.now
        f.clock.advance(4 * 3600)
        let noon = try f.diary.log(food: food, quantity: .base(100), slotID: "lunch", day: d)
        try f.diary.log(food: decaf, quantity: .base(250), slotID: "lunch", day: d)
        try f.diary.log(food: unknown, quantity: .base(250), slotID: "lunch", day: d)
        let gone = try f.diary.log(food: food, quantity: .base(250), slotID: "lunch", day: d)
        try f.diary.softDelete(entryIDs: [gone.id])
        try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d.adding(days: 3))

        let intakes = try f.diary.caffeineIntakes(in: d.previous ... d)
        #expect(intakes.map(\.id) == [morning.id, noon.id])
        #expect(intakes.map(\.mg) == [100, 40])
        #expect(intakes.first?.loggedAt == morningTime)
        #expect(intakes.first?.name == "Filter coffee")
        #expect(intakes.first?.day == d)
        #expect(intakes.map(\.dose) == [CaffeineDose(mg: 100, at: morningTime), CaffeineDose(mg: 40, at: noon.loggedAt)])
        #expect(try f.diary.caffeineIntakes(in: d.next ... d.adding(days: 2)).isEmpty)
    }

    @Test func `intakes combine quick-adds and the diary`() async throws {
        let f = try Fixture()
        let food = try coffee(f)
        var iterator = f.caffeine.observeIntakes(in: d.previous ... d).makeAsyncIterator()
        #expect(try await iterator.next() == CaffeineIntakes())

        let start = f.clock.now
        let espresso = try f.caffeine.add(mg: 64, day: d, loggedAt: start.addingTimeInterval(3600), drinkID: "espresso")
        #expect(try await iterator.next()?.quickAdds.map(\.id) == [espresso.id])

        let entry = try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d)
        let both = try #require(try await iterator.next())
        #expect(both.diary.map(\.id) == [entry.id])
        #expect(both.doses == [CaffeineDose(mg: 100, at: start), CaffeineDose(mg: 64, at: start.addingTimeInterval(3600))])
        #expect(both.totalMg(on: d) == 164)
        #expect(both.totalMg(on: d.previous) == 0)
        #expect(try f.caffeine.intakes(in: d.previous ... d) == both)

        try f.diary.softDelete(entryIDs: [entry.id])
        #expect(try await iterator.next()?.diary.isEmpty == true)
    }

    @Test func `merging foods fills in missing caffeine`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Coffee")
        let other = try coffee(f)
        let merged = try f.foods.merge(keep: keep.id, remove: [other.id])
        #expect(merged.food.caffeineMg100 == nil) // liquid vs solid: different bases, not copied

        let liquid = try f.foods.save(FoodDetail(food: Food(name: "Coffee", per100: .zero, isLiquid: true))).food
        let source = try coffee(f)
        #expect(try f.foods.merge(keep: liquid.id, remove: [source.id]).food.caffeineMg100 == 40)
    }

    @Test func `caffeine survives export and import`() throws {
        let f = try Fixture()
        let food = try coffee(f)
        try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d)
        try f.caffeine.add(mg: 64, day: d, drinkID: "espresso", name: "Espresso")
        let deleted = try f.caffeine.add(mg: 95, day: d)
        try f.caffeine.softDelete(ids: [deleted.id]) // the tombstone goes along
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: [[String: Any]]])
        #expect(tables["caffeine_entry"]?.count == 2)
        #expect(tables["diary_entry"]?.first?["caffeine_mg"] as? Double == 100)
        #expect(tables["food"]?.first?["caffeine_mg_100"] as? Double == 40)

        let target = try Fixture()
        try DataPortability(target.db, clock: f.clock.appClock).importJSON(json, mode: .replace)
        #expect(try DataPortability(target.db, clock: f.clock.appClock).exportJSON() == json)
        #expect(try target.caffeine.intakes(in: d ... d) == f.caffeine.intakes(in: d ... d))
        #expect(try target.caffeine.entry(id: deleted.id)?.deletedAt != nil)
        #expect(try target.foods.food(id: food.id)?.caffeineMg100 == 40)
    }

    @Test func `an export from before caffeine still imports`() throws {
        let f = try Fixture()
        let food = try coffee(f)
        try f.diary.log(food: food, quantity: .base(250), slotID: "breakfast", day: d)
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var tables = try #require(object["tables"] as? [String: [[String: Any]]])
        tables["caffeine_entry"] = nil
        tables["diary_entry"] = tables["diary_entry"]?.map { $0.filter { $0.key != "caffeine_mg" } }
        tables["food"] = tables["food"]?.map { $0.filter { $0.key != "caffeine_mg_100" } }
        object["tables"] = tables
        object["schemaVersion"] = 8
        let old = try JSONSerialization.data(withJSONObject: object)

        let target = try Fixture()
        try DataPortability(target.db, clock: f.clock.appClock).importJSON(old, mode: .replace)
        #expect(try target.diary.totals(for: d).kcal == 5)
        #expect(try target.diary.totals(for: d).caffeineMg == nil)
        #expect(try target.caffeine.intakes(in: d ... d) == CaffeineIntakes())
    }

    @Test func `csv export has a caffeine column`() throws {
        let f = try Fixture()
        try f.diary.log(food: try coffee(f), quantity: .base(250), slotID: "breakfast", day: d)
        let diary = try #require(try DataPortability(f.db).exportCSV()["diary.csv"])
        let lines = diary.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0].contains(",sodium_mg,caffeine_mg,quick_add,"))
        #expect(lines[1].hasSuffix(",5,100,0,"))
    }
}
