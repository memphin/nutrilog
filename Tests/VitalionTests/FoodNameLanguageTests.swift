import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// Settings → Food names (FR-74): built-in food names in a language of their own, apart from the app language.
@MainActor
struct FoodNameLanguageTests {
    /// The bundled index's salmon (FDC 175168).
    private static let salmonEN = "Fish, salmon, Atlantic, farmed, cooked, dry heat"
    private static let salmonHR = "Losos, atlantski, uzgojeni, pečen"

    private func bundledSalmon(_ env: AppEnvironment) throws -> BundledFood {
        let hit = try #require(try env.search?.search("salmon atlantic farmed cooked").first)
        guard case let .bundled(food) = hit else {
            Issue.record("expected a bundled food, got \(hit)")
            throw CancellationError()
        }
        return food
    }

    /// How "same as app" resolves is tested in Core; here: the environment names built-in foods that way by default.
    @Test func `built-in names follow the app language by default`() throws {
        #expect(try bundledSalmon(AppEnvironment.preview(appFoodNameLanguage: .english)).name == Self.salmonEN)
        #expect(try bundledSalmon(AppEnvironment.preview(appFoodNameLanguage: .croatian)).name == Self.salmonHR)
    }

    @Test func `choosing croatian in an english app switches search, saved foods and the diary, and back`() throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .english)
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        let copy = try foods.localCopy(of: bundledSalmon(env))
        let entry = try diary.log(food: copy, quantity: .base(150), slotID: "dinner", day: env.today)
        let planned = try #require(env.mealPlan).plan(food: copy, quantity: .base(150), slotID: "dinner", day: env.today.next)
        #expect(copy.name == Self.salmonEN)

        try env.setFoodNamePreference(.croatian)
        #expect(env.foodNamePreference == .croatian)
        #expect(env.foodNameLanguage == .croatian)
        #expect(try env.profiles?.setting(SettingKey.foodNames, as: String.self) == "hr")
        #expect(try foods.food(id: copy.id)?.name == Self.salmonHR)
        #expect(try diary.entry(id: entry.id)?.displayName == Self.salmonHR)
        #expect(try env.mealPlan?.entry(id: planned.id)?.displayName == Self.salmonHR)
        #expect(try env.search?.search("salmon").first?.name == Self.salmonHR) // the saved copy, found by English
        #expect(env.dataGeneration == 1) // screens reload, pending undos are dropped

        try env.setFoodNamePreference(.sameAsApp)
        #expect(try env.profiles?.setting(SettingKey.foodNames, as: String.self) == "sameAsApp")
        #expect(try foods.food(id: copy.id)?.name == copy.name)
        #expect(try foods.food(id: copy.id)?.nameLocal == copy.nameLocal)
        #expect(try diary.entry(id: entry.id)?.displayName == entry.displayName)
        #expect(try env.mealPlan?.entry(id: planned.id)?.displayName == planned.displayName)
    }

    @Test func `a launch rename started before a change can't undo it`() async throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .english)
        let copy = try #require(env.foods).localCopy(of: bundledSalmon(env))
        let entry = try #require(env.diary).log(food: copy, quantity: .base(150), slotID: "dinner", day: env.today)
        let launch = env.applyFoodNameLanguageInBackground() // started with English
        try env.setFoodNamePreference(.croatian)
        await launch?.value
        #expect(try env.foods?.food(id: copy.id)?.name == Self.salmonHR)
        #expect(try env.diary?.entry(id: entry.id)?.displayName == Self.salmonHR)
    }

    @Test func `english in a croatian app shows english names`() throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .croatian)
        try env.setFoodNamePreference(.english)
        #expect(env.foodNameLanguage == .english)
        #expect(try bundledSalmon(env).name == Self.salmonEN)
    }

    @Test func `a choice that resolves to the same language changes nothing`() throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .english)
        let id = try #require(env.foods).localCopy(of: bundledSalmon(env)).id
        let stored = try env.foods?.food(id: id)
        try env.setFoodNamePreference(.english)
        #expect(try env.foods?.food(id: id) == stored) // same revision and updated_at
        #expect(env.dataGeneration == 0)
    }

    @Test func `the stored choice is read at start and applied in the background`() async throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .english)
        let copy = try #require(env.foods).localCopy(of: bundledSalmon(env))
        try env.profiles?.setSetting(SettingKey.foodNames, FoodNamePreference.croatian.rawValue)
        try env.reloadSettings()
        #expect(env.foodNameLanguage == .croatian)

        await env.applyFoodNameLanguageInBackground()?.value
        #expect(try env.foods?.food(id: copy.id)?.name == Self.salmonHR)
        #expect(env.dataGeneration == 1)
        // Idempotent: nothing left to change.
        await env.applyFoodNameLanguageInBackground()?.value
        #expect(env.dataGeneration == 1)
    }

    @Test func `an import brings the choice along and the names follow it`() throws {
        let env = AppEnvironment.preview(appFoodNameLanguage: .english)
        let portability = try #require(env.portability)
        let copy = try #require(env.foods).localCopy(of: bundledSalmon(env))
        try env.setFoodNamePreference(.croatian)
        let exported = try portability.exportJSON()
        try env.setFoodNamePreference(.sameAsApp)

        try portability.importJSON(exported, mode: .replace)
        try env.dataDidChangeExternally()
        #expect(env.foodNamePreference == .croatian)
        #expect(try env.foods?.food(id: copy.id)?.name == Self.salmonHR)
    }

    @Test func `a scanned product is named in croatian when chosen`() async throws {
        let product = OFFProduct(
            code: "3850104012341", productName: "Vegeta food seasoning", productNameHR: "Vegeta dodatak jelima",
            nutriments: ["energy-kcal_100g": 160, "proteins_100g": 9, "carbohydrates_100g": 25, "fat_100g": 1],
        )
        let env = AppEnvironment.preview(openFoodFacts: StubOpenFoodFactsClient(products: [product]), appFoodNameLanguage: .english)
        try env.setFoodNamePreference(.croatian)
        let result = try await #require(env.barcodeLookup).resolve("3850104012341")
        guard case let .remote(remote) = result else {
            Issue.record("expected an Open Food Facts product, got \(result)")
            return
        }
        #expect(remote.draft.name == "Vegeta dodatak jelima")
        #expect(remote.draft.nameLocal == "Vegeta food seasoning")
    }
}
