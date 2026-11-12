import Core
import FoodSources
import Foundation
import Persistence
import Testing
@testable import FoodLookup

/// Settings → Food names for scanned Open Food Facts products: a new copy is named in the chosen language when the
/// product has a Croatian name; a copy saved before keeps its name.
struct FoodNameLanguageLookupTests {
    private static let vegeta = "3850104012341"

    private func product() -> OFFProduct {
        OFFProduct(
            code: Self.vegeta, productName: "Vegeta food seasoning", productNameHR: "Vegeta dodatak jelima",
            nutriments: ["energy-kcal_100g": 160, "proteins_100g": 9, "carbohydrates_100g": 25, "fat_100g": 1],
        )
    }

    @Test func `croatian names a new copy in croatian`() async throws {
        let f = try Fixture([Self.vegeta: .product(product())])
        let lookup = BarcodeLookup(database: f.db, client: f.client, nameLanguage: .croatian, clock: f.clock.appClock)
        let remote = try #require(try await lookup.resolve(Self.vegeta).remote)
        #expect(remote.draft.name == "Vegeta dodatak jelima")
        #expect(remote.draft.nameLocal == "Vegeta food seasoning")
        let saved = try f.foods.saveRemoteCopy(remote.draft)
        #expect(saved.food.name == "Vegeta dodatak jelima")
        #expect(saved.food.nameLocal == "Vegeta food seasoning")
    }

    @Test func `english keeps the main name, also from the cache`() async throws {
        let f = try Fixture([Self.vegeta: .product(product())])
        let croatian = BarcodeLookup(database: f.db, client: f.client, nameLanguage: .croatian, clock: f.clock.appClock)
        _ = try await croatian.resolve(Self.vegeta) // cached now
        let english = BarcodeLookup(database: f.db, client: f.client, nameLanguage: .english, clock: f.clock.appClock)
        let remote = try #require(try await english.resolve(Self.vegeta).remote)
        #expect(remote.origin == .cache)
        #expect(remote.draft.name == "Vegeta food seasoning")
        #expect(remote.draft.nameLocal == "Vegeta dodatak jelima")
    }

    @Test func `a saved copy keeps its name in another language`() async throws {
        let f = try Fixture([Self.vegeta: .product(product())])
        let english = BarcodeLookup(database: f.db, client: f.client, nameLanguage: .english, clock: f.clock.appClock)
        let saved = try f.foods.saveRemoteCopy(#require(try await english.resolve(Self.vegeta).remote).draft)
        let croatian = BarcodeLookup(database: f.db, client: f.client, nameLanguage: .croatian, clock: f.clock.appClock)
        #expect(try await croatian.resolve(Self.vegeta) == .local(saved))
    }
}
