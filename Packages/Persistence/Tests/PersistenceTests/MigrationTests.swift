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
}
