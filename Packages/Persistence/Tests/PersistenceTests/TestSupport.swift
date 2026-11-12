import Core
import Foundation
import GRDB
@testable import Persistence

/// A clock tests can advance.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_200_000)) { // 2026-11-09 ~04:53 UTC
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var appClock: AppClock {
        AppClock { [self] in now }
    }
}

struct Fixture {
    let db: AppDatabase
    let clock: TestClock
    var foods: FoodRepository {
        FoodRepository(db, clock: clock.appClock)
    }

    var diary: DiaryRepository {
        DiaryRepository(db, clock: clock.appClock)
    }

    var profiles: ProfileRepository {
        ProfileRepository(db, clock: clock.appClock)
    }

    var water: WaterRepository {
        WaterRepository(db, clock: clock.appClock)
    }

    var caffeine: CaffeineRepository {
        CaffeineRepository(db, clock: clock.appClock)
    }

    var trainingDays: TrainingDayRepository {
        TrainingDayRepository(db, clock: clock.appClock)
    }

    var healthLinks: HealthKitLinkRepository {
        HealthKitLinkRepository(db, clock: clock.appClock)
    }

    init() throws {
        db = try AppDatabase.inMemory()
        clock = TestClock()
    }

    @discardableResult
    func makeFood(
        _ name: String, kcal: Double = 100, protein: Double = 10, carbs: Double = 10, fat: Double = 2,
        brand: String? = nil, nameLocal: String? = nil, servings: [Serving] = [], barcodes: [String] = [],
    ) throws -> Food {
        let food = Food(
            name: name,
            nameLocal: nameLocal,
            brand: brand,
            per100: Nutrients(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat),
        )
        return try foods.save(FoodDetail(food: food, servings: servings, barcodes: barcodes)).food
    }
}

func day(_ string: String) -> LocalDay {
    LocalDay(string)!
}

extension BundledFoodIndex {
    /// English names, for tests that don't care about the food name language.
    func search(_ query: String, limit: Int) throws -> [BundledFood] {
        try search(query, limit: limit, language: .english)
    }

    /// English names, for tests that don't care about the food name language.
    func food(id: String) throws -> BundledFood? {
        try food(id: id, language: .english)
    }
}

extension FoodSearch {
    /// English names, for tests that don't care about the food name language.
    init(_ database: AppDatabase, bundled: BundledFoodIndex?) {
        self.init(database, bundled: bundled, nameLanguage: .english)
    }
}

/// Writes a small bundled index with the same schema as tools/build_food_index.py.
func makeBundledIndex(rows: [(id: String, fdc: String, name: String, kcal: Double)]) throws -> BundledFoodIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE bundled_food (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL,
            kcal_100 REAL NOT NULL, protein_g_100 REAL NOT NULL, carbs_g_100 REAL NOT NULL, fat_g_100 REAL NOT NULL,
            fiber_g_100 REAL, sugar_g_100 REAL, sat_fat_g_100 REAL, sodium_mg_100 REAL);
        CREATE VIRTUAL TABLE bundled_food_fts USING fts5(name, content='bundled_food', content_rowid='rowid',
            tokenize="unicode61 remove_diacritics 2");
        """)
        for row in rows {
            try db.execute(
                sql: "INSERT INTO bundled_food VALUES (?,?,?,?,1,2,3,NULL,NULL,NULL,NULL)",
                arguments: [row.id, row.fdc, row.name, row.kcal],
            )
        }
        try db.execute(sql: "INSERT INTO bundled_food_fts(bundled_food_fts) VALUES ('rebuild')")
    }
    try queue.close()
    return try BundledFoodIndex(url: url)
}

/// Writes a bundled index with Croatian names (`name_hr`, FTS over both names) as tools/build_food_index.py does now,
/// and returns its file so a test can open it in either language.
func makeBilingualIndexFile(rows: [(id: String, fdc: String, name: String, nameHR: String?)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-hr-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE bundled_food (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL,
            kcal_100 REAL NOT NULL, protein_g_100 REAL NOT NULL, carbs_g_100 REAL NOT NULL, fat_g_100 REAL NOT NULL,
            fiber_g_100 REAL, sugar_g_100 REAL, sat_fat_g_100 REAL, sodium_mg_100 REAL, caffeine_mg_100 REAL,
            name_hr TEXT);
        CREATE VIRTUAL TABLE bundled_food_fts USING fts5(name, name_hr, content='bundled_food', content_rowid='rowid',
            tokenize="unicode61 remove_diacritics 2");
        """)
        for row in rows {
            try db.execute(
                sql: "INSERT INTO bundled_food VALUES (?,?,?,100,1,2,3,NULL,NULL,NULL,NULL,NULL,?)",
                arguments: [row.id, row.fdc, row.name, row.nameHR],
            )
        }
        try db.execute(sql: "INSERT INTO bundled_food_fts(bundled_food_fts) VALUES ('rebuild')")
    }
    try queue.close()
    return url
}
