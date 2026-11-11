import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct OFFProductCacheTests {
    let f: Fixture
    var cache: OFFProductCache {
        OFFProductCache(f.db, clock: f.clock.appClock)
    }

    init() throws {
        f = try Fixture()
    }

    @Test func `stores and reads a product`() throws {
        let json = Data(#"{"code":"3017620422003"}"#.utf8)
        try cache.storeProduct(barcode: "3017620422003", json: json, lastModifiedT: 1_700_000_000)
        let entry = try #require(try cache.entry(barcode: "3017620422003"))
        #expect(entry.content == .product(json: json, lastModifiedT: 1_700_000_000))
        #expect(entry.fetchedAt == f.clock.now)
        #expect(try cache.entry(barcode: "4006381333931") == nil)
    }

    @Test func `not found replaces a product and vice versa`() throws {
        try cache.storeProduct(barcode: "3017620422003", json: Data("{}".utf8), lastModifiedT: nil)
        f.clock.advance(60)
        try cache.storeNotFound(barcode: "3017620422003")
        var entry = try #require(try cache.entry(barcode: "3017620422003"))
        #expect(entry.content == .notFound)
        #expect(entry.age(at: f.clock.now) == 0)
        try cache.storeProduct(barcode: "3017620422003", json: Data("{}".utf8), lastModifiedT: nil)
        entry = try #require(try cache.entry(barcode: "3017620422003"))
        #expect(entry.content == .product(json: Data("{}".utf8), lastModifiedT: nil))
        #expect(try cache.count() == 1)
    }

    @Test func `evicts only entries older than the max age`() throws {
        let day: TimeInterval = 86400
        try cache.storeProduct(barcode: "1111111111116", json: Data("{}".utf8), lastModifiedT: nil) // 100 days old
        f.clock.advance(9 * day)
        try cache.storeNotFound(barcode: "2222222222222") // 91 days old
        f.clock.advance(2 * day)
        try cache.storeProduct(barcode: "3333333333338", json: Data("{}".utf8), lastModifiedT: nil) // 89 days old
        f.clock.advance(89 * day)
        let maxAge = 90 * day
        let evicted = try cache.evictEntries(olderThan: maxAge)
        #expect(evicted == 2)
        #expect(try cache.entry(barcode: "1111111111116") == nil)
        #expect(try cache.entry(barcode: "2222222222222") == nil)
        #expect(try cache.entry(barcode: "3333333333338") != nil)
        try cache.removeEntry(barcode: "3333333333338")
        #expect(try cache.count() == 0)
    }

    @Test func `schema enforces json exactly for found rows`() throws {
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO off_product_cache (barcode, status, json, fetched_at) VALUES ('1', 'found', NULL, 'x')
                """)
            }
        }
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO off_product_cache (barcode, status, json, fetched_at) VALUES ('1', 'not_found', '{}', 'x')
                """)
            }
        }
    }

    @Test func `cache is not exported`() throws {
        try cache.storeProduct(barcode: "3017620422003", json: Data("{}".utf8), lastModifiedT: nil)
        let data = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: Any])
        #expect(tables["off_product_cache"] == nil)
        #expect(!DataPortability.tables.contains("off_product_cache"))
    }
}

struct FoodCopyTests {
    let f: Fixture

    init() throws {
        f = try Fixture()
    }

    func offCopy(_ code: String = "3017620422003", name: String = "Nutella", kcal: Double = 539) -> FoodDetail {
        FoodDetail(
            food: Food(
                name: name, source: .off, sourceID: code,
                per100: Nutrients(kcal: kcal, proteinG: 6.3, carbsG: 57.5, fatG: 30.9),
            ),
            servings: [Serving(label: "1 portion (15 g)", grams: 15)],
            barcodes: [code],
        )
    }

    @Test func `inserts a copy once`() throws {
        let first = try f.foods.saveCopy(offCopy())
        let second = try f.foods.saveCopy(offCopy(name: "Nutella (newer)"))
        #expect(second.food.id == first.food.id)
        #expect(second.food.name == "Nutella")
        #expect(first.barcodes == ["3017620422003"])
        #expect(first.servings.map(\.label) == ["1 portion (15 g)"])
        let count = try f.db.reader.read { db in try Food.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func `the food already carrying the barcode wins`() throws {
        let mine = try f.makeFood("My Nutella", barcodes: ["3017620422003"])
        let copy = try f.foods.saveCopy(offCopy())
        #expect(copy.food.id == mine.id)
        #expect(copy.food.source == .custom)
    }

    @Test func `matches by source id and links a free barcode`() throws {
        var withoutBarcode = offCopy()
        withoutBarcode.barcodes = []
        let first = try f.foods.saveCopy(withoutBarcode)
        #expect(first.barcodes.isEmpty)
        let second = try f.foods.saveCopy(offCopy())
        #expect(second.food.id == first.food.id)
        #expect(second.barcodes == ["3017620422003"])
        #expect(try f.foods.food(barcode: "3017620422003")?.food.id == first.food.id)
    }

    @Test func `takes a barcode over from a deleted food`() throws {
        var withoutBarcode = offCopy()
        withoutBarcode.barcodes = []
        let copy = try f.foods.saveCopy(withoutBarcode)
        let old = try f.makeFood("Old custom food", barcodes: ["3017620422003"])
        try f.foods.softDelete(id: old.id)
        let linked = try f.foods.saveCopy(offCopy())
        #expect(linked.food.id == copy.food.id)
        #expect(linked.barcodes == ["3017620422003"])
    }

    @Test func `revives a deleted copy with fresh values`() throws {
        let first = try f.foods.saveCopy(offCopy())
        try f.foods.setFavorite(id: first.food.id, true)
        try f.foods.softDelete(id: first.food.id)
        f.clock.advance(60)
        let revived = try f.foods.saveCopy(offCopy(kcal: 540))
        #expect(revived.food.id == first.food.id)
        #expect(revived.food.deletedAt == nil)
        #expect(revived.food.kcal100 == 540)
        #expect(revived.food.isFavorite)
        #expect(revived.servings.map(\.id) == first.servings.map(\.id))
        #expect(try f.foods.food(barcode: "3017620422003")?.food.id == first.food.id)
    }

    @Test func `a revived copy keeps its "counts as a drink" choice`() throws {
        var first = try f.foods.saveCopy(offCopy())
        first.food.countsAsFluid = false
        try f.foods.save(first)
        try f.foods.softDelete(id: first.food.id)
        f.clock.advance(60)
        let revived = try f.foods.saveCopy(offCopy(kcal: 540))
        #expect(revived.food.id == first.food.id)
        #expect(revived.food.countsAsFluid == false)
    }

    @Test func `linking a barcode bumps the copy and the deleted previous owner`() throws {
        var withoutBarcode = offCopy()
        withoutBarcode.barcodes = []
        let copy = try f.foods.saveCopy(withoutBarcode)
        let old = try f.makeFood("Old custom food", barcodes: ["3017620422003"])
        try f.foods.softDelete(id: old.id)
        let oldRevision = try #require(try f.foods.food(id: old.id)).revision
        f.clock.advance(60)
        let linked = try f.foods.saveCopy(offCopy())
        let copyRevision = copy.food.revision + 1
        #expect(linked.food.revision == copyRevision)
        #expect(linked.food.updatedAt == f.clock.now)
        let oldAfter = try #require(try f.foods.food(id: old.id))
        let bumpedOldRevision = oldRevision + 1
        #expect(oldAfter.revision == bumpedOldRevision)
        #expect(oldAfter.updatedAt == f.clock.now)

        f.clock.advance(60) // nothing to link: unchanged
        #expect(try f.foods.saveCopy(offCopy()).food.revision == linked.food.revision)
    }

    @Test func `revived copy keeps the last serving only while it still exists`() throws {
        let first = try f.foods.saveCopy(offCopy())
        let serving = try #require(first.servings.first)
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE food SET last_serving_id = ?, last_amount = 2 WHERE id = ?", arguments: [serving.id, first.food.id])
        }
        try f.foods.softDelete(id: first.food.id)
        let same = try f.foods.saveCopy(offCopy()) // same serving label → same serving row
        #expect(same.food.lastServingID == serving.id)
        #expect(same.food.lastAmount == 2)

        try f.foods.softDelete(id: first.food.id)
        var changed = offCopy()
        changed.servings = [Serving(label: "1 jar (400 g)", grams: 400)]
        let revived = try f.foods.saveCopy(changed)
        #expect(revived.food.id == first.food.id)
        #expect(revived.food.lastServingID == nil)
        #expect(revived.food.lastAmount == nil)
    }

    @Test func `revived copy keeps a remembered base amount`() throws {
        let first = try f.foods.saveCopy(offCopy())
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE food SET last_amount = 40 WHERE id = ?", arguments: [first.food.id])
        }
        try f.foods.softDelete(id: first.food.id)
        var changed = offCopy()
        changed.servings = []
        let revived = try f.foods.saveCopy(changed)
        #expect(revived.food.lastServingID == nil)
        #expect(revived.food.lastAmount == 40)
    }

    @Test func `concurrent copies produce one food`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitalion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let foods = try FoodRepository(AppDatabase.onDisk(directory: dir)) // a pool: real concurrent writers
        let detail = offCopy()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try foods.saveCopy(detail).food.id }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        let count = try await foods.database.reader.read { db in try Food.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func `drops invalid barcodes instead of failing`() throws {
        var detail = offCopy()
        detail.barcodes = ["3017620422003", "12345", "3017620422003"]
        let copy = try f.foods.saveCopy(detail)
        #expect(copy.barcodes == ["3017620422003"])
    }

    @Test func `lookup by candidate list tries each key in order`() throws {
        let upce = try f.makeFood("UPC-E product", barcodes: ["0012345000065"])
        #expect(try f.foods.food(barcodes: ["01234565", "0012345000065"])?.food.id == upce.id)
        let ean8 = try f.makeFood("EAN-8 product", barcodes: ["01234565"])
        #expect(try f.foods.food(barcodes: ["01234565", "0012345000065"])?.food.id == ean8.id)
        #expect(try f.foods.food(barcodes: []) == nil)
    }
}
