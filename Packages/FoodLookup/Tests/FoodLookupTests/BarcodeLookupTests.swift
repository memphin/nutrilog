import Core
import FoodSources
import Foundation
import Persistence
import Testing
@testable import FoodLookup

private let nutella = "3017620422003"
/// Valid both as EAN-8 and as UPC-E; as UPC-E it expands to ``ambiguousUPCE``.
private let ambiguous = "01234565"
private let ambiguousUPCE = "0012345000065"

struct BarcodeLookupTests {
    // MARK: Local

    @Test func `local food wins without a request`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        let mine = try f.foods.save(FoodDetail(
            food: Food(name: "My Nutella", per100: Nutrients(kcal: 530, proteinG: 6, carbsG: 58, fatG: 31)),
            barcodes: [nutella],
        ))
        let result = try await f.lookup.resolve(nutella)
        #expect(result == .local(mine))
        #expect(f.client.requests.isEmpty)
    }

    @Test func `upc a input finds the food stored as ean 13`() async throws {
        let f = try Fixture()
        let mine = try f.foods.save(FoodDetail(
            food: Food(name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0)),
            barcodes: ["0036000291452"],
        ))
        #expect(try await f.lookup.resolve("036000291452", symbology: .upcA) == .local(mine))
    }

    // MARK: Network and cache

    @Test func `miss then network caches the product`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        let remote = try #require(try await f.lookup.resolve(nutella).remote)
        #expect(remote.origin == .network)
        #expect(remote.barcode == nutella)
        #expect(remote.draft.barcode == nutella)
        #expect(remote.draft.name == "Nutella")
        #expect(remote.quality == .complete)
        #expect(remote.fetchedAt == f.clock.now)
        #expect(!remote.isStale)
        #expect(f.client.requests == [nutella])

        let entry = try #require(try f.cache.entry(barcode: nutella))
        guard case let .product(json, lastModifiedT) = entry.content else {
            Issue.record("expected a cached product")
            return
        }
        #expect(lastModifiedT == 1_700_000_000)
        #expect(try JSONDecoder().decode(OFFProduct.self, from: json) == offProduct(nutella))
    }

    @Test func `fresh cache answers without a request`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        let fetchedAt = f.clock.now
        f.clock.advance(days: 29)
        f.client.set(nutella, .failure(.offline)) // must not be asked
        let remote = try #require(try await f.lookup.resolve(nutella).remote)
        #expect(remote.origin == .cache)
        #expect(remote.fetchedAt == fetchedAt)
        #expect(remote.draft.name == "Nutella")
        #expect(f.client.requests == [nutella])
    }

    @Test func `stale cache is refreshed from the network`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        f.clock.advance(days: 31)
        f.client.set(nutella, .product(offProduct(nutella, name: "Nutella 2", kcal: 540)))
        let remote = try #require(try await f.lookup.resolve(nutella).remote)
        #expect(remote.origin == .network)
        #expect(remote.draft.name == "Nutella 2")
        #expect(f.client.requests == [nutella, nutella])
        #expect(try f.cache.entry(barcode: nutella)?.fetchedAt == f.clock.now)
    }

    @Test func `stale cache is served when offline`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        let fetchedAt = f.clock.now
        f.clock.advance(days: 60)
        f.client.set(nutella, .failure(.offline))
        let remote = try #require(try await f.lookup.resolve(nutella).remote)
        #expect(remote.origin == .staleCache)
        #expect(remote.isStale)
        #expect(remote.fetchedAt == fetchedAt)
        #expect(remote.draft.name == "Nutella")
        #expect(try f.cache.entry(barcode: nutella)?.fetchedAt == fetchedAt) // not re-stamped
    }

    @Test func `stale cache is served when the server fails`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        f.clock.advance(days: 31)
        f.client.set(nutella, .failure(.server(status: 503)))
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .staleCache)
    }

    @Test func `future cache timestamp counts as expired`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        try f.cache.storeProduct(barcode: nutella, json: JSONEncoder().encode(offProduct(nutella)), lastModifiedT: nil)
        f.clock.advance(days: -1) // the clock went back
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .network)
    }

    @Test func `unreadable cached product is fetched again`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        try f.cache.storeProduct(barcode: nutella, json: Data("[1,2]".utf8), lastModifiedT: nil)
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .network)
        f.client.set(nutella, .failure(.offline))
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .cache) // and the cache was repaired
    }

    @Test func `broken cache row falls through to the network`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        try await f.db.writer.write { db in
            try db.execute(sql: """
            INSERT INTO off_product_cache (barcode, status, json, fetched_at) VALUES (?, 'found', '{}', 'not a date')
            """, arguments: [nutella])
        }
        #expect(throws: (any Error).self) { try f.cache.entry(barcode: nutella) } // the row really is unreadable
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .network)
        #expect(try f.cache.entry(barcode: nutella) != nil) // replaced by a readable row
    }

    @Test func `candidates are normalized and invalid ones dropped`() async throws {
        let f = try Fixture(["0036000291452": .product(offProduct("0036000291452", name: "Cola"))])
        let remote = try #require(try await f.lookup.resolve(candidates: ["123", "036000291452", "0036000291452"]).remote)
        #expect(remote.barcode == "0036000291452")
        #expect(f.client.requests == ["0036000291452"])
    }

    // MARK: Not found and failures

    @Test func `not found is cached for seven days`() async throws {
        let f = try Fixture()
        #expect(try await f.lookup.resolve(nutella) == .notFound(barcode: nutella))
        #expect(try f.cache.entry(barcode: nutella)?.content == .notFound)
        f.clock.advance(days: 6.9)
        #expect(try await f.lookup.resolve(nutella) == .notFound(barcode: nutella))
        #expect(f.client.requests == [nutella])

        f.clock.advance(days: 0.2) // 7.1 days: ask again, and OFF has it now
        f.client.set(nutella, .product(offProduct(nutella)))
        #expect(try await f.lookup.resolve(nutella).remote?.origin == .network)
        #expect(f.client.requests == [nutella, nutella])
    }

    @Test func `stale product removed from OFF becomes not found`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        f.clock.advance(days: 31)
        f.client.set(nutella, .failure(.notFound))
        #expect(try await f.lookup.resolve(nutella) == .notFound(barcode: nutella))
        #expect(try f.cache.entry(barcode: nutella)?.content == .notFound)
    }

    @Test func `offline without cache throws offline`() async throws {
        let f = try Fixture([nutella: .failure(.offline)])
        await #expect(throws: BarcodeLookupError.offline) {
            try await f.lookup.resolve(nutella)
        }
        #expect(try f.cache.entry(barcode: nutella) == nil) // a failure is never cached
    }

    @Test func `offline with only an expired not found throws offline`() async throws {
        let f = try Fixture()
        _ = try await f.lookup.resolve(nutella)
        f.clock.advance(days: 8)
        f.client.set(nutella, .failure(.offline))
        await #expect(throws: BarcodeLookupError.offline) {
            try await f.lookup.resolve(nutella)
        }
    }

    @Test(arguments: [OpenFoodFactsError.timedOut, .rateLimited, .server(status: 500), .invalidResponse])
    func `other failures without cache throw unavailable`(error: OpenFoodFactsError) async throws {
        let f = try Fixture([nutella: .failure(error)])
        await #expect(throws: BarcodeLookupError.unavailable(error)) {
            try await f.lookup.resolve(nutella)
        }
    }

    @Test func `invalid code throws without a request`() async throws {
        let f = try Fixture()
        await #expect(throws: BarcodeLookupError.invalidBarcode) {
            try await f.lookup.resolve("12345")
        }
        await #expect(throws: BarcodeLookupError.invalidBarcode) {
            try await f.lookup.resolve(candidates: [])
        }
        #expect(f.client.requests.isEmpty)
    }

    @Test func `cancellation with a stale entry propagates instead of serving it`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella)
        f.clock.advance(days: 31)
        f.client.set(nutella, .cancelled)
        await #expect(throws: CancellationError.self) {
            try await f.lookup.resolve(nutella)
        }
    }

    @Test func `cancellation propagates`() async throws {
        let f = try Fixture([nutella: .cancelled])
        await #expect(throws: CancellationError.self) {
            try await f.lookup.resolve(nutella)
        }
    }

    // MARK: Ambiguous 8-digit codes

    @Test func `ambiguous code tries each reading in order`() async throws {
        let f = try Fixture([ambiguousUPCE: .product(offProduct(ambiguousUPCE, name: "Gum"))])
        let remote = try #require(try await f.lookup.resolve(ambiguous).remote)
        #expect(remote.barcode == ambiguousUPCE)
        #expect(remote.draft.barcode == ambiguousUPCE)
        #expect(f.client.requests == [ambiguous, ambiguousUPCE])
        #expect(try f.cache.entry(barcode: ambiguous)?.content == .notFound)

        // Next scan: the EAN-8 reading is a fresh not-found, the UPC-E reading a fresh product: no request.
        #expect(try await f.lookup.resolve(ambiguous).remote?.origin == .cache)
        #expect(f.client.requests.count == 2)
    }

    @Test func `first reading wins when both exist`() async throws {
        let f = try Fixture([
            ambiguous: .product(offProduct(ambiguous, name: "EAN-8 product")),
            ambiguousUPCE: .product(offProduct(ambiguousUPCE, name: "UPC-E product")),
        ])
        #expect(try await f.lookup.resolve(ambiguous).remote?.draft.name == "EAN-8 product")
        #expect(try await f.lookup.resolve(candidates: [ambiguousUPCE, ambiguous]).remote?.draft.name == "UPC-E product")
    }

    @Test func `symbology hint decides the readings`() async throws {
        let f = try Fixture([ambiguousUPCE: .product(offProduct(ambiguousUPCE, name: "Gum"))])
        #expect(try await f.lookup.resolve(ambiguous, symbology: .ean8) == .notFound(barcode: ambiguous))
        #expect(f.client.requests == [ambiguous]) // an explicit EAN-8 is never read as UPC-E
        #expect(try await f.lookup.resolve(ambiguous, symbology: .upcE).remote?.barcode == ambiguousUPCE)
        #expect(f.client.requests == [ambiguous, ambiguousUPCE])
    }

    @Test func `local food under any reading wins`() async throws {
        let f = try Fixture([ambiguous: .product(offProduct(ambiguous))])
        let gum = try f.foods.save(FoodDetail(
            food: Food(name: "Gum", per100: Nutrients(kcal: 200, proteinG: 0, carbsG: 60, fatG: 0)),
            barcodes: [ambiguousUPCE],
        ))
        #expect(try await f.lookup.resolve(ambiguous) == .local(gum))
        #expect(f.client.requests.isEmpty)
    }

    @Test func `not found for every reading reports the most likely key`() async throws {
        let f = try Fixture()
        #expect(try await f.lookup.resolve(ambiguous) == .notFound(barcode: ambiguous))
        #expect(f.client.requests == [ambiguous, ambiguousUPCE])
    }

    @Test func `offline stops after the first request and falls back to any cached reading`() async throws {
        let f = try Fixture([ambiguousUPCE: .product(offProduct(ambiguousUPCE, name: "Gum"))])
        _ = try await f.lookup.resolve(ambiguous) // caches not-found for EAN-8, product for UPC-E
        f.clock.advance(days: 40) // both expired
        f.client.set(ambiguous, .failure(.offline))
        f.client.set(ambiguousUPCE, .failure(.offline))
        let remote = try #require(try await f.lookup.resolve(ambiguous).remote)
        #expect(remote.origin == .staleCache)
        #expect(remote.barcode == ambiguousUPCE)
        #expect(f.client.requests == [ambiguous, ambiguousUPCE, ambiguous]) // the UPC-E reading wasn't requested
    }

    // MARK: Saving and eviction

    @Test func `saved remote copy resolves locally afterwards`() async throws {
        let f = try Fixture([ambiguousUPCE: .product(offProduct("12345000065", name: "Gum"))]) // OFF's own code form
        let remote = try #require(try await f.lookup.resolve(ambiguous).remote)
        let saved = try f.foods.saveRemoteCopy(remote.draft)
        #expect(saved.barcodes == [ambiguousUPCE])
        #expect(saved.food.source == .off)
        #expect(saved.food.sourceID == "12345000065")
        #expect(try await f.lookup.resolve(ambiguous) == .local(saved))
        #expect(try f.foods.saveRemoteCopy(remote.draft).food.id == saved.food.id) // idempotent
    }

    @Test func `eviction removes entries older than ninety days`() async throws {
        let f = try Fixture([nutella: .product(offProduct(nutella))])
        _ = try await f.lookup.resolve(nutella) // product, day 0
        _ = try await f.lookup.resolve("4006381333931") // not found, day 0
        f.clock.advance(days: 5)
        f.client.set("5000112637922", .product(offProduct("5000112637922", name: "Cola")))
        _ = try await f.lookup.resolve("5000112637922") // product, day 5
        f.clock.advance(days: 89)
        #expect(try f.lookup.evictExpiredCache() == 2) // 94 days old
        #expect(try f.cache.entry(barcode: nutella) == nil)
        #expect(try f.cache.entry(barcode: "4006381333931") == nil)
        #expect(try f.cache.entry(barcode: "5000112637922") != nil) // 89 days old
        f.clock.advance(days: 2)
        #expect(try BarcodeLookup.evictExpiredCache(in: f.db, clock: f.clock.appClock) == 1)
        #expect(try f.cache.count() == 0)
    }

    @Test func `standard policy`() {
        let policy = BarcodeLookup.CachePolicy.standard
        let days = [policy.productTTL, policy.notFoundTTL, policy.evictionAge].map { $0 / 86400 }
        #expect(days == [30, 7, 90])
    }
}
