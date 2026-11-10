import Foundation
import GRDB
import Testing
@testable import Persistence

struct MigrationTests {
    @Test func `migrates from scratch`() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for expected in ["food", "diary_entry", "daily_metrics", "target", "tdee_estimate", "water_entry", "meal_slot", "profile"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test func `seeds default meal slots and profile`() throws {
        let db = try AppDatabase.inMemory()
        let (slots, profiles) = try db.reader.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meal_slot")!,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile")!,
            )
        }
        #expect(slots == 4)
        #expect(profiles == 1)
    }

    @Test func `fts is diacritic insensitive`() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: """
            INSERT INTO food (id, name, name_local, source, kcal_100, protein_g_100, carbs_g_100, fat_g_100, created_at, updated_at)
            VALUES ('f1', 'Chocolate', 'Čokolada', 'custom', 540, 6, 55, 31, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """)
        }
        let hits = try db.reader.read { db in
            try String.fetchAll(db, sql: """
            SELECT food.name FROM food_fts JOIN food ON food.rowid = food_fts.rowid WHERE food_fts MATCH ?
            """, arguments: ["cokolada"])
        }
        #expect(hits == ["Chocolate"])
    }

    @Test func `migrations are idempotent`() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue) // second run must be a no-op
        let applied = try queue.read { try Migrator.make().appliedMigrations($0) }
        #expect(applied == Migrator.migrations)
    }

    @Test func `migration 008 turns recipes into ordinary custom foods and keeps their data`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        for name in Migrator.migrations.prefix(7) {
            old.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
        }
        try old.migrate(queue)
        let stamp = "2026-01-01T00:00:00.000Z"
        try queue.write { db in
            for (id, source, kcal) in [("oats", "custom", 370.0), ("chili", "recipe", 190.0), ("cola", "off", 42.0)] {
                try db.execute(
                    sql: """
                    INSERT INTO food (id, name, source, kcal_100, protein_g_100, carbs_g_100, fat_g_100, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 10, 20, 5, ?, ?)
                    """,
                    arguments: [id, id.capitalized, source, kcal, stamp, stamp],
                )
            }
            try db.execute(
                sql: """
                INSERT INTO recipe_ingredient (id, recipe_id, food_id, display_name, grams, kcal_100, protein_g_100, carbs_g_100,
                    fat_g_100, created_at, updated_at)
                VALUES ('i1', 'chili', 'oats', 'Oats', 100, 370, 13, 60, 7, ?, ?)
                """,
                arguments: [stamp, stamp],
            )
        }
        let db = try AppDatabase(queue)
        #expect(try queue.read { try Migrator.make().appliedMigrations($0) } == Migrator.migrations)
        let foods = FoodRepository(db)
        let chili = try #require(try foods.food(id: "chili"))
        #expect(chili.source == .custom)
        #expect(chili.kcal100 == 190)
        #expect(chili.revision == 2)
        #expect(chili.updatedAt > chili.createdAt) // the migration's timestamp parses like any other
        // Other foods are untouched; the old ingredient rows stay.
        let oats = try #require(try foods.food(id: "oats"))
        #expect(oats.source == .custom)
        #expect(oats.revision == 1)
        #expect(try foods.food(id: "cola")?.source == .off)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recipe_ingredient") } == 1)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM food WHERE source = 'recipe'") } == 0)
        #expect(try foods.customFoods().map(\.id) == ["chili", "oats"])
    }

    @Test func `importing an old export turns its recipes into custom foods`() throws {
        let f = try Fixture()
        let oats = try f.makeFood("Oats")
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE food SET source = 'recipe' WHERE id = ?", arguments: [oats.id])
        }
        let export = try f.portability.exportJSON()
        #expect(String(bytes: export, encoding: .utf8)?.contains("\"recipe\"") == true)

        let target = try Fixture()
        try target.portability.importJSON(export, mode: .replace)
        #expect(try target.foods.food(id: oats.id)?.source == .custom)
        try f.portability.importJSON(export, mode: .merge)
        #expect(try f.foods.food(id: oats.id)?.source == .custom)
    }
}

struct OnDiskDatabaseTests {
    @Test func `opens migrates and reopens on disk`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitalion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try AppDatabase.onDisk(directory: dir)
        try first.writer.write { db in
            try db.execute(sql: "UPDATE profile SET height_cm = 181")
        }
        let reopened = try AppDatabase.onDisk(directory: dir)
        let height = try reopened.reader.read { db in try Double.fetchOne(db, sql: "SELECT height_cm FROM profile") }
        #expect(height == 181)
        let mode = try reopened.reader.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nutrilog.sqlite").path))
    }
}
