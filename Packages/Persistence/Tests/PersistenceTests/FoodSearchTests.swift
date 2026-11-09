import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct FoodSearchTests {
    @Test func `prefix diacritic and case insensitive`() throws {
        let f = try Fixture()
        try f.makeFood("Chocolate", brand: "Kraš", nameLocal: "Čokolada")
        try f.makeFood("Chicken breast")
        try f.makeFood("Chickpeas")
        let search = FoodSearch(f.db, bundled: nil)
        #expect(try search.search("cokolada").map(\.name) == ["Chocolate"])
        #expect(try search.search("KRAS").map(\.name) == ["Chocolate"])
        #expect(try search.search("chick br").map(\.name) == ["Chicken breast"])
        #expect(try Set(search.search("chick").map(\.name)) == ["Chicken breast", "Chickpeas"])
        #expect(try search.search("  ").isEmpty)
        #expect(try search.search("\"*)(").isEmpty) // FTS syntax characters are neutralised
    }

    @Test func `excludes deleted and ranks used foods first`() throws {
        let f = try Fixture()
        let plain = try f.makeFood("Milk")
        let used = try f.makeFood("Milk chocolate drink with a long name")
        let deleted = try f.makeFood("Milk old")
        try f.foods.softDelete(id: deleted.id)
        try f.diary.log(food: used, quantity: .base(200), slotID: "snacks", day: day("2026-11-09"))
        let results = try FoodSearch(f.db, bundled: nil).search("milk")
        #expect(results.map(\.id) == ["food:\(used.id)", "food:\(plain.id)"])
    }

    @Test func `merges bundled results without duplicating local copies`() throws {
        let f = try Fixture()
        let index = try makeBundledIndex(rows: [
            ("b1", "171705", "Bananas, raw", 89),
            ("b2", "173944", "Bananas, dehydrated", 346),
            ("b3", "169640", "Honey", 304),
        ])
        #expect(try index.count() == 3)
        #expect(try index.food(id: "b3")?.per100.kcal == 304)
        #expect(try index.food(id: "nope") == nil)
        try f.makeFood("Banana bread")
        let search = FoodSearch(f.db, bundled: index)

        let before = try search.search("banana")
        #expect(before.first?.source == .custom)
        #expect(before.filter { $0.source == .bundled }.count == 2)

        let raw = try #require(try index.food(id: "b1"))
        try f.foods.localCopy(of: raw)
        let after = try search.search("banana")
        #expect(after.count == 3) // local copy replaces the bundled row
        #expect(after.compactMap {
            if case let .bundled(item) = $0 {
                item.name
            } else {
                nil
            }
        } == ["Bananas, dehydrated"])
        #expect(after.contains {
            if case let .food(food) = $0 {
                food.sourceID == "171705"
            } else {
                false
            }
        })
        #expect(try search.search("banana", limit: 1).count == 1)
        #expect(after.allSatisfy { !$0.id.isEmpty && $0.per100.kcal > 0 })
        #expect(try index.search("", limit: 5).isEmpty)
    }

    @Test func `result accessors`() {
        let food = Food(name: "Ajvar", brand: "Podravka", per100: Nutrients(kcal: 80, proteinG: 1, carbsG: 8, fatG: 4))
        let bundled = BundledFood(id: "x", sourceID: "1", name: "Peppers", per100: .zero)
        #expect(FoodSearchResult.food(food).brand == "Podravka")
        #expect(FoodSearchResult.bundled(bundled).brand == nil)
        #expect(FoodSearchResult.bundled(bundled).name == "Peppers")
        #expect(FoodSearchResult.bundled(bundled).id == "bundled:x")
    }

    @Test func `ten thousand rows under 100 ms`() throws {
        let f = try Fixture()
        let words = ["chicken", "beef", "pork", "rice", "bread", "milk", "cheese", "apple", "banana", "tomato", "pepper", "oil"]
        let now = Timestamp.string(f.clock.now)
        try f.db.writer.write { db in
            for i in 0 ..< 10000 {
                let name = "\(words[i % words.count]) \(words[(i / 12) % words.count]) item \(i)"
                try db.execute(sql: """
                INSERT INTO food (id, name, source, kcal_100, protein_g_100, carbs_g_100, fat_g_100, use_count, created_at, updated_at)
                VALUES (?, ?, 'custom', 100, 1, 1, 1, ?, ?, ?)
                """, arguments: [UUID().uuidString, name, i % 7, now, now])
            }
        }
        let search = FoodSearch(f.db, bundled: nil)
        _ = try search.search("warm up")
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for query in ["chick", "bread mi", "ban", "pep oil", "item 99"] {
                _ = try search.search(query)
            }
        }
        #expect(elapsed / 5 < .milliseconds(100), "average search took \(elapsed / 5)")
    }

    @Test func `real bundled index is searchable`() throws {
        // The committed index (tools/build_food_index.py output) — skipped when run outside the repo.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FoodIndex/bundled_foods.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let index = try BundledFoodIndex(url: url)
        #expect(try index.count() >= 300)
        #expect(try index.search("banana raw", limit: 5).contains { $0.name == "Bananas, raw" })
    }
}
