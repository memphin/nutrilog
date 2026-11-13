import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// A bundled / USDA copy merged away (Duplicate foods) stays merged: `food.merged_into_id`, migration 012.
struct FoodMergeTrackingTests {
    private let raw = BundledFood(
        id: "b1", sourceID: "171705", name: "Bananas, raw", per100: Nutrients(kcal: 89, proteinG: 1.1, carbsG: 22.8, fatG: 0.3),
    )

    private func index() throws -> BundledFoodIndex {
        try makeBundledIndex(rows: [("b1", "171705", "Bananas, raw", 89)])
    }

    private func activeFoods(_ f: Fixture) throws -> Int {
        try f.db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food WHERE deleted_at IS NULL") ?? 0 }
    }

    @Test func `merge records the kept food and search no longer offers the bundled row`() throws {
        let f = try Fixture()
        let search = try FoodSearch(f.db, bundled: index())
        let copy = try f.foods.localCopy(of: raw)
        let mine = try f.makeFood("Banana")
        try f.foods.merge(keep: mine.id, remove: [copy.id])

        #expect(try f.foods.food(id: copy.id)?.mergedIntoID == mine.id)
        #expect(try f.foods.food(id: mine.id)?.mergedIntoID == nil)
        // The kept food matches "banana" itself; the bundled row stays hidden.
        #expect(try search.search("banana").map(\.id) == ["food:\(mine.id)"])
        // A query only the bundled name matches shows nothing rather than the bundled row.
        #expect(try search.search("bananas raw").isEmpty)
    }

    @Test func `picking the bundled row of a merged copy returns the kept food`() throws {
        let f = try Fixture()
        let copy = try f.foods.localCopy(of: raw)
        let mine = try f.makeFood("Banana")
        try f.foods.merge(keep: mine.id, remove: [copy.id])

        #expect(try f.foods.localCopy(of: raw).id == mine.id)
        let online = try f.foods.saveCopy(FoodDetail(food: Food(name: "Bananas, raw", source: .usda, sourceID: "171705", per100: raw.per100)))
        #expect(online.food.id == mine.id)
        #expect(try f.foods.food(id: copy.id)?.deletedAt != nil) // not revived
        #expect(try activeFoods(f) == 1)
        #expect(try f.foods.duplicateGroups().isEmpty)
    }

    @Test func `a merged USDA copy also resolves to the kept food`() throws {
        let f = try Fixture()
        let online = try f.foods.saveCopy(FoodDetail(food: Food(name: "Bananas, raw", source: .usda, sourceID: "171705", per100: raw.per100)))
        let mine = try f.makeFood("Banana")
        try f.foods.merge(keep: mine.id, remove: [online.food.id])
        #expect(try FoodSearch(f.db, bundled: index()).search("bananas raw").isEmpty)
        #expect(try f.foods.localCopy(of: raw).id == mine.id)
        #expect(try activeFoods(f) == 1)
    }

    @Test func `a chain of two merges resolves to the final food`() throws {
        let f = try Fixture()
        let search = try FoodSearch(f.db, bundled: index())
        let copy = try f.foods.localCopy(of: raw)
        let first = try f.makeFood("Banana")
        let final = try f.makeFood("Banana fresh")
        try f.foods.merge(keep: first.id, remove: [copy.id])
        try f.foods.merge(keep: final.id, remove: [first.id])

        #expect(try f.foods.food(id: copy.id)?.mergedIntoID == first.id)
        #expect(try f.foods.food(id: first.id)?.mergedIntoID == final.id)
        #expect(try search.search("banana").map(\.id) == ["food:\(final.id)"])
        #expect(try f.foods.localCopy(of: raw).id == final.id)
        #expect(try activeFoods(f) == 1)
    }

    @Test func `a cycle of merge links does not hang and falls back to reviving`() throws {
        let f = try Fixture()
        let copy = try f.foods.localCopy(of: raw)
        let other = try f.makeFood("Banana")
        try f.foods.merge(keep: other.id, remove: [copy.id])
        try f.foods.softDelete(id: other.id)
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE food SET merged_into_id = ? WHERE id = ?", arguments: [copy.id, other.id])
        }
        let search = try FoodSearch(f.db, bundled: index())
        #expect(try search.search("banana").map(\.source) == [.bundled])
        #expect(try f.foods.localCopy(of: raw).id == copy.id)
    }

    @Test func `when the kept food is deleted later the copy is revived and its link cleared`() throws {
        let f = try Fixture()
        let search = try FoodSearch(f.db, bundled: index())
        let copy = try f.foods.localCopy(of: raw)
        let mine = try f.makeFood("Banana")
        try f.foods.merge(keep: mine.id, remove: [copy.id])
        try f.foods.softDelete(id: mine.id)

        #expect(try search.search("banana").map(\.source) == [.bundled])
        let revived = try f.foods.localCopy(of: raw)
        #expect(revived.id == copy.id)
        #expect(revived.deletedAt == nil)
        #expect(revived.mergedIntoID == nil)
        #expect(try f.foods.food(id: copy.id)?.mergedIntoID == nil)
        #expect(try activeFoods(f) == 1)

        // Same through saveCopy (online USDA hit).
        let g = try Fixture()
        let online = try g.foods.saveCopy(FoodDetail(food: Food(name: "Bananas, raw", source: .usda, sourceID: "171705", per100: raw.per100)))
        let kept = try g.makeFood("Banana")
        try g.foods.merge(keep: kept.id, remove: [online.food.id])
        try g.foods.softDelete(id: kept.id)
        let again = try g.foods.saveCopy(FoodDetail(food: Food(name: "Bananas, raw", source: .usda, sourceID: "171705", per100: raw.per100)))
        #expect(again.food.id == online.food.id)
        #expect(again.food.deletedAt == nil)
        #expect(try g.foods.food(id: online.food.id)?.mergedIntoID == nil)
    }

    @Test func `a plain delete still brings the bundled row back and picking it revives the copy`() throws {
        let f = try Fixture()
        let search = try FoodSearch(f.db, bundled: index())
        let copy = try f.foods.localCopy(of: raw)
        try f.foods.softDelete(id: copy.id)
        #expect(try f.foods.food(id: copy.id)?.mergedIntoID == nil)
        #expect(try search.search("banana").map(\.source) == [.bundled])
        let revived = try f.foods.localCopy(of: raw)
        #expect(revived.id == copy.id)
        #expect(revived.deletedAt == nil)
    }

    @Test func `migration 012 adds the column to an existing database`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        for name in Migrator.migrations.prefix(while: { $0 != "012_food_merged_into" }) {
            if let migrate = Migrator.codedMigration(named: name, deviceCalendar: .gregorian) {
                old.registerMigration(name, migrate: migrate)
            } else {
                old.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
            }
        }
        try old.migrate(queue)
        let stamp = "2026-01-01T00:00:00.000Z"
        try queue.write { db in
            #expect(try !db.columns(in: "food").map(\.name).contains("merged_into_id"))
            try db.execute(
                sql: """
                INSERT INTO food (id, name, source, source_id, kcal_100, protein_g_100, carbs_g_100, fat_g_100, created_at, updated_at)
                VALUES ('old', 'Bananas, raw', 'bundled', '171705', 89, 1, 22, 0, ?, ?)
                """,
                arguments: [stamp, stamp],
            )
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        let food = try #require(try FoodRepository(db).food(id: "old"))
        #expect(food.mergedIntoID == nil)
        #expect(food.name == "Bananas, raw")
    }

    @Test func `export and import keep the merge link and old exports without it still import`() throws {
        let f = try Fixture()
        let copy = try f.foods.localCopy(of: raw)
        let mine = try f.makeFood("Banana")
        try f.foods.merge(keep: mine.id, remove: [copy.id])
        let portability = DataPortability(f.db, clock: f.clock.appClock)
        let export = try portability.exportJSON()
        #expect(String(bytes: export, encoding: .utf8)?.contains("\"merged_into_id\" : \"\(mine.id)\"") == true)

        let target = try Fixture()
        try DataPortability(target.db, clock: target.clock.appClock).importJSON(export, mode: .replace)
        #expect(try target.foods.food(id: copy.id)?.mergedIntoID == mine.id)
        #expect(try target.foods.localCopy(of: raw).id == mine.id)
        #expect(try DataPortability(target.db, clock: target.clock.appClock).exportJSON() == export)

        // An export made before migration 012 has no `merged_into_id` key and an older schema version.
        var file = try JSONDecoder().decode(ExportFile.self, from: export)
        file.schemaVersion = DataPortability.schemaVersion - 1
        file.tables["food"] = file.tables["food"]?.map { $0.filter { $0.key != "merged_into_id" } }
        let oldExport = try JSONEncoder().encode(file)
        let older = try Fixture()
        try DataPortability(older.db, clock: older.clock.appClock).importJSON(oldExport, mode: .replace)
        #expect(try older.foods.food(id: copy.id)?.mergedIntoID == nil)
        #expect(try older.foods.food(id: copy.id)?.deletedAt != nil)
        #expect(try older.foods.food(id: mine.id)?.deletedAt == nil)
    }
}

struct FoodMergeTests {
    let d = day("2026-11-09")

    @Test func `finds duplicates by barcode and by name and brand`() throws {
        let f = try Fixture()
        let mine = try f.makeFood("Milk 2.8%", brand: "Dukat")
        let typo = try f.makeFood("milk 2,8 %", brand: "DUKAT")
        var off = FoodDetail(food: Food(name: "Trajno mlijeko", brand: "Dukat", source: .off, sourceID: "4006381333931", per100: .zero))
        off.food.dataQuality = .energyOnly
        let offCopy = try f.foods.save(off).food
        let scanned = try f.makeFood("Dukat milk", barcodes: ["4006381333931"])
        _ = try f.makeFood("Oats")
        _ = try f.makeFood("Rice")
        try f.diary.log(food: typo, quantity: .base(100), slotID: "lunch", day: d)

        let groups = try f.foods.duplicateGroups()
        #expect(groups.count == 2)
        // Groups come by their keeper's name. Suggested keeper first: complete data before an energy-only online copy…
        #expect(groups[0].map(\.food.id) == [scanned.id, offCopy.id])
        // …and the most used of two equally good foods.
        #expect(groups[1].map(\.food.id) == [typo.id, mine.id])
    }

    @Test func `merge re-points entries and meals and keeps the best data`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Milk", kcal: 60, servings: [Serving(label: "glass", grams: 250)])
        var extraDetail = FoodDetail(
            food: Food(
                name: "Milk",
                brand: "Dukat",
                per100: Nutrients(kcal: 64, proteinG: 3, carbsG: 5, fatG: 3, sugarG: 4.7, sodiumMg: 40),
            ),
            servings: [Serving(label: "glass", grams: 200), Serving(label: "carton", grams: 1000)],
            barcodes: ["4006381333931"],
        )
        extraDetail.food.nameLocal = "Mlijeko"
        let extra = try f.foods.save(extraDetail)
        try f.foods.setFavorite(id: extra.food.id, true)
        let entry = try f.diary.log(food: extra.food, quantity: .base(200), slotID: "breakfast", day: d)
        f.clock.advance(3600)
        try f.diary.log(food: keep, quantity: .base(100), slotID: "lunch", day: d)
        let carton = try #require(extra.servings.first { $0.label == "carton" })
        let meal = try f.meals.create(name: "Latte", items: [.init(foodID: extra.food.id, grams: 1000, servingID: carton.id)])
        // A row of the legacy recipe table (recipes were removed, issue #68) still follows the merge.
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO recipe_ingredient (id, recipe_id, food_id, display_name, grams, kcal_100, protein_g_100, carbs_g_100,
                    fat_g_100, created_at, updated_at)
                VALUES ('legacy', ?, ?, 'Milk', 500, 64, 3, 5, 3, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                arguments: [keep.id, extra.food.id],
            )
        }
        let totals = try f.diary.totals(for: d)
        f.clock.advance(3600)

        let merged = try f.foods.merge(keep: keep.id, remove: [extra.food.id])
        #expect(merged.food.id == keep.id)
        #expect(merged.food.kcal100 == 60) // the kept food's own values win
        #expect(merged.food.brand == "Dukat")
        #expect(merged.food.nameLocal == "Mlijeko")
        #expect(merged.food.sugarG100 == 4.7)
        #expect(merged.food.sodiumMg100 == 40)
        #expect(merged.food.isFavorite)
        #expect(merged.food.useCount == 2)
        #expect(merged.barcodes == ["4006381333931"])
        #expect(merged.servings.map(\.label) == ["glass", "carton"])
        #expect(merged.servings[0].grams == 250) // same label: the kept food's serving stays

        // History is the same, now pointing at the kept food.
        #expect(try f.diary.entry(id: entry.id)?.foodID == keep.id)
        #expect(try f.diary.entry(id: entry.id)?.kcal == entry.kcal)
        #expect(try f.diary.totals(for: d) == totals)
        let mealItem = try #require(try f.meals.detail(id: meal.id)?.items.first)
        #expect(mealItem.food.id == keep.id)
        #expect(mealItem.item.servingID == nil)
        #expect(mealItem.item.grams == 1000)
        #expect(!mealItem.isFoodDeleted)
        let legacy = try #require(try f.db.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT food_id, kcal_100 FROM recipe_ingredient WHERE id = 'legacy'")
        })
        let legacyFoodID: String? = legacy["food_id"]
        let legacyKcal: Double? = legacy["kcal_100"]
        #expect(legacyFoodID == keep.id)
        #expect(legacyKcal == 64) // snapshot untouched

        #expect(try f.foods.food(id: extra.food.id)?.deletedAt != nil)
        #expect(try f.foods.food(barcode: "4006381333931")?.food.id == keep.id)
        #expect(try f.foods.duplicateGroups().isEmpty)
    }

    @Test func `merge carries a "counts as a drink" choice to a kept food on Automatic`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Shake")
        var extra = try f.foods.save(FoodDetail(food: Food(name: "Shake", per100: Nutrients(kcal: 80, proteinG: 8, carbsG: 6, fatG: 2))))
        extra.food.countsAsFluid = false
        try f.foods.save(extra)
        #expect(try f.foods.merge(keep: keep.id, remove: [extra.food.id]).food.countsAsFluid == false)

        // The kept food's own choice wins.
        var chosen = try f.foods.save(FoodDetail(food: Food(name: "Juice", per100: Nutrients(kcal: 45, proteinG: 0, carbsG: 11, fatG: 0))))
        chosen.food.countsAsFluid = true
        chosen = try f.foods.save(chosen)
        var other = try f.foods.save(FoodDetail(food: Food(name: "Juice", per100: Nutrients(kcal: 45, proteinG: 0, carbsG: 11, fatG: 0))))
        other.food.countsAsFluid = false
        try f.foods.save(other)
        #expect(try f.foods.merge(keep: chosen.food.id, remove: [other.food.id]).food.countsAsFluid == true)
    }

    @Test func `merge is all or nothing`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Milk")
        let other = try f.makeFood("Milk", brand: "Dukat", barcodes: ["4006381333931"])
        let entry = try f.diary.log(food: other, quantity: .base(100), slotID: "lunch", day: d)
        let before = try f.portability.exportJSON()

        // The second food to remove doesn't exist: the first must not be merged either.
        #expect(throws: Persistence.PersistenceError.notFound("missing")) { try f.foods.merge(keep: keep.id, remove: [other.id, "missing"])
        }
        #expect(try f.portability.exportJSON() == before)
        #expect(try f.diary.entry(id: entry.id)?.foodID == other.id)
        #expect(try f.foods.food(id: other.id)?.deletedAt == nil)

        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: keep.id, remove: [keep.id]) }
        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: keep.id, remove: []) }
        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: "missing", remove: [other.id]) }
    }
}
