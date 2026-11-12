import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Croatian names in the bundled index: searchable in any language, shown in Croatian when the food name language
/// is Croatian.
struct BundledFoodNamesTests {
    private let rows: [(id: String, fdc: String, name: String, nameHR: String?)] = [
        ("b1", "175168", "Fish, salmon, Atlantic, farmed, cooked, dry heat", "Losos, atlantski, uzgojeni, pečen"),
        ("b2", "169704", "Rice, brown, long-grain, cooked", "Riža, smeđa, dugozrnata, kuhana"),
        ("b3", "169451", "Beef, variety meats and by-products, liver, raw", "Jetra, goveđa, sirova"),
        ("b4", "173944", "Bananas, raw", nil),
    ]

    @Test func `croatian query finds the food in an english app and vice versa`() throws {
        let index = try BundledFoodIndex(url: makeBilingualIndexFile(rows: rows))
        #expect(try index.search("losos", limit: 5, language: .english).map(\.name) == ["Fish, salmon, Atlantic, farmed, cooked, dry heat"])
        #expect(try index.search("salmon", limit: 5, language: .english).map(\.id) == ["b1"])

        #expect(try index.search("salmon", limit: 5, language: .croatian).map(\.name) == ["Losos, atlantski, uzgojeni, pečen"])
        #expect(try index.search("losos", limit: 5, language: .croatian).map(\.id) == ["b1"])
    }

    @Test func `croatian query ignores diacritics including đ`() throws {
        let index = try BundledFoodIndex(url: makeBilingualIndexFile(rows: rows))
        for query in ["losos pecen", "LOSOS PEČEN", "pečen", "riza smeda", "riža smeđa", "smedja", "jetra goveda", "govedja"] {
            #expect(try index.search(query, limit: 5, language: .croatian).count == 1, "\(query)")
        }
        #expect(try index.search("riza smeda", limit: 5, language: .croatian).map(\.id) == ["b2"])
        #expect(try index.search("govedja", limit: 5, language: .croatian).map(\.id) == ["b3"])
        // English words with a "d" still match as before.
        #expect(try index.search("dry heat", limit: 5, language: .croatian).map(\.id) == ["b1"])
        #expect(try index.search("brown cooked", limit: 5, language: .croatian).map(\.id) == ["b2"])
    }

    @Test func `shown name follows the language and falls back to english`() throws {
        let index = try BundledFoodIndex(url: makeBilingualIndexFile(rows: rows))
        let salmon = try #require(try index.food(id: "b1", language: .croatian))
        #expect(salmon.name == "Losos, atlantski, uzgojeni, pečen")
        #expect(salmon.englishName == "Fish, salmon, Atlantic, farmed, cooked, dry heat")
        #expect(salmon.croatianName == "Losos, atlantski, uzgojeni, pečen")
        #expect(salmon.names == ["Losos, atlantski, uzgojeni, pečen", "Fish, salmon, Atlantic, farmed, cooked, dry heat"])
        #expect(FoodSearchResult.bundled(salmon).names == salmon.names)

        // No Croatian name (NULL): English, in either language.
        let banana = try #require(try index.food(id: "b4", language: .croatian))
        #expect(banana.name == "Bananas, raw")
        #expect(banana.croatianName == nil)
        #expect(banana.names == ["Bananas, raw"])
        #expect(try index.search("banana", limit: 5, language: .croatian).map(\.name) == ["Bananas, raw"])

        let englishSalmon = try #require(try index.food(id: "b1", language: .english))
        #expect(englishSalmon.name == "Fish, salmon, Atlantic, farmed, cooked, dry heat")
        #expect(englishSalmon.croatianName == "Losos, atlantski, uzgojeni, pečen")
        #expect(englishSalmon.names.first == englishSalmon.englishName)
    }

    @Test func `index without the croatian column still works`() throws {
        let old = try makeBundledIndex(rows: [("b1", "171705", "Bananas, raw", 89)])
        let food = try #require(try old.search("banana", limit: 5).first)
        #expect(food.name == "Bananas, raw")
        #expect(food.croatianName == nil)
        #expect(try old.food(id: "b1")?.name == "Bananas, raw")
    }

    @Test func `old index opened in croatian shows english names`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-old-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE bundled_food (
                id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL,
                kcal_100 REAL NOT NULL, protein_g_100 REAL NOT NULL, carbs_g_100 REAL NOT NULL, fat_g_100 REAL NOT NULL,
                fiber_g_100 REAL, sugar_g_100 REAL, sat_fat_g_100 REAL, sodium_mg_100 REAL);
            CREATE VIRTUAL TABLE bundled_food_fts USING fts5(name, content='bundled_food', content_rowid='rowid',
                tokenize="unicode61 remove_diacritics 2");
            INSERT INTO bundled_food VALUES ('b1', '173944', 'Bananas, raw', 89, 1, 23, 0.3, NULL, NULL, NULL, NULL);
            INSERT INTO bundled_food_fts(bundled_food_fts) VALUES ('rebuild');
            """)
        }
        try queue.close()
        let index = try BundledFoodIndex(url: url)
        #expect(try index.search("bananas raw", limit: 5, language: .croatian).map(\.name) == ["Bananas, raw"])
        #expect(try index.food(id: "b1", language: .croatian)?.croatianName == nil)
        #expect(try index.food(id: "b1", language: .croatian)?.name == "Bananas, raw")
    }

    @Test func `local copy takes the shown name`() throws {
        let index = try BundledFoodIndex(url: makeBilingualIndexFile(rows: rows))
        let croatianFixture = try Fixture()
        let copy = try croatianFixture.foods.localCopy(of: #require(try index.food(id: "b1", language: .croatian)))
        #expect(copy.name == "Losos, atlantski, uzgojeni, pečen")
        #expect(copy.nameLocal == "Fish, salmon, Atlantic, farmed, cooked, dry heat")
        #expect(copy.source == .bundled)
        #expect(copy.sourceID == "175168")

        // Unified search in an English app: the Croatian query finds the bundled food; once copied, the copy (with
        // the English name, the Croatian one in `nameLocal`) stands for it under either name.
        let englishFixture = try Fixture()
        let search = FoodSearch(englishFixture.db, bundled: index, nameLanguage: .english)
        #expect(try search.search("losos").map(\.id) == ["bundled:b1"])
        let englishCopy = try englishFixture.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        #expect(englishCopy.name == "Fish, salmon, Atlantic, farmed, cooked, dry heat")
        #expect(englishCopy.nameLocal == "Losos, atlantski, uzgojeni, pečen")
        #expect(try search.search("salmon").map(\.id) == ["food:\(englishCopy.id)"])
        #expect(try search.search("losos").map(\.id) == ["food:\(englishCopy.id)"])
    }

    @Test func `d variants`() {
        #expect(FoodSearch.dVariants("losos") == ["losos"])
        #expect(FoodSearch.dVariants("smeda") == ["smeda", "smeđa"])
        #expect(FoodSearch.dVariants("govedja") == ["govedja", "goveđa"]) // "dj" is one "đ"
        #expect(FoodSearch.dVariants("dddd").count == 8) // capped at the first three d's
        #expect(FoodSearch.ftsPattern("riza") == "\"riza\"*")
        #expect(FoodSearch.ftsPattern("smeda riza") == "(\"smeda\"* OR \"smeđa\"*) AND \"riza\"*")
    }

    @Test func `real bundled index has a croatian name for every food`() throws {
        // The committed index (tools/build_food_index.py + tools/food_names_hr.csv) — skipped when run outside the repo.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FoodIndex/bundled_foods.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        let (total, missing) = try queue.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundled_food") ?? 0,
                String.fetchAll(db, sql: """
                SELECT source_id || ' ' || name FROM bundled_food WHERE name_hr IS NULL OR trim(name_hr) = ''
                """),
            )
        }
        try queue.close()
        #expect(total >= 300)
        #expect(missing.isEmpty, "foods without a Croatian name: \(missing)")

        let index = try BundledFoodIndex(url: url)
        #expect(try index.search("losos pecen", limit: 5, language: .croatian).contains { $0.name == "Losos, atlantski, uzgojeni, pečen" })
        #expect(try index.search("banana raw", limit: 5, language: .croatian).contains { $0.englishName == "Bananas, raw" })
    }
}
