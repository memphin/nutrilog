import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// A bundled / USDA copy merged away (Duplicate foods) stays merged: `food.merged_into_id`, migration 011.
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

    @Test func `migration 011 adds the column to an existing database`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        for name in Migrator.migrations.prefix(while: { $0 != "011_food_merged_into" }) {
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

        // An export made before migration 011 has no `merged_into_id` key and an older schema version.
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
