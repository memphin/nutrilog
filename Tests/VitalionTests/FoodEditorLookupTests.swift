import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// Scanning in Foods → New food (#69): the code is added and the product is looked up like in Add Food's scanner,
/// so a known product fills the form. Model level with a stub Open Food Facts client (the simulator has no camera).
@MainActor
struct FoodEditorLookupTests {
    private func environment(failure: OpenFoodFactsError? = nil) -> AppEnvironment {
        let client = StubOpenFoodFactsClient(
            products: [ScanFlowTests.complete, ScanFlowTests.energyOnly, ScanFlowTests.perServing], failure: failure,
        )
        return AppEnvironment.preview(clock: ManualClock().appClock, openFoodFacts: client)
    }

    /// What the editor's scanner does with a scanned code.
    private func scan(_ code: String, into model: FoodEditorModel, env: AppEnvironment) async -> FoodEditorModel.ScanLookup {
        let candidates = Barcode.candidates(code, symbology: .ean13)
        #expect(model.insertScanned(candidates: candidates) == .added(code))
        return await model.lookUpScanned(candidates: candidates, using: env.barcodeLookup)
    }

    @Test func `scanning a known product fills a new food and saves it with the barcode`() async throws {
        let env = environment()
        let foods = try #require(env.foods)
        let model = FoodEditorModel(energyUnit: .kcal)
        #expect(!model.canSave)

        #expect(await scan(ScanFlowTests.nutella, into: model, env: env) == .filled(name: "Nutella"))
        #expect(model.name == "Nutella")
        #expect(model.brand == "Ferrero")
        #expect(model.basis == .per100)
        #expect(model.per100 == Nutrients(kcal: 539, proteinG: 6.3, carbsG: 57.5, fatG: 30.9))
        #expect(model.servings.map(\.amount) == [Format.field(15)])
        #expect(model.barcodes == [ScanFlowTests.nutella])
        #expect(model.canSave)

        let saved = try #require(try model.save(to: foods))
        #expect(saved.food.source == .custom) // the user's own food, not a copy of the online one
        #expect(saved.barcodes == [ScanFlowTests.nutella])
        // The next scan anywhere finds it locally.
        let again = try await env.barcodeLookup?.resolve(ScanFlowTests.nutella)
        #expect(again == .local(saved))
    }

    @Test func `a typed name is kept and typed values are never overwritten`() async {
        let env = environment()
        let named = FoodEditorModel(energyUnit: .kcal, initialName: "Lino Lada")
        #expect(await scan(ScanFlowTests.nutella, into: named, env: env) == .filled(name: "Nutella"))
        #expect(named.name == "Lino Lada")
        #expect(named.energy == Format.field(539))

        let typed = FoodEditorModel(energyUnit: .kcal)
        typed.energy = "500"
        #expect(!typed.canFillFromLookup)
        #expect(await scan(ScanFlowTests.nutella, into: typed, env: env) == .skipped)
        #expect(typed.energy == "500" && typed.name.isEmpty)
        #expect(typed.barcodes == [ScanFlowTests.nutella]) // the code is still added
    }

    @Test func `values the source lacks stay empty, per-serving products ask for the serving size`() async {
        let env = environment()
        let partial = FoodEditorModel(energyUnit: .kcal)
        #expect(await scan(ScanFlowTests.partialCode, into: partial, env: env) == .filled(name: "Mystery bar"))
        #expect(partial.energy == Format.field(450))
        #expect(partial.protein.isEmpty && partial.carbs.isEmpty && partial.fat.isEmpty)
        #expect(!partial.canSave)

        let perServing = FoodEditorModel(energyUnit: .kcal)
        #expect(await scan(ScanFlowTests.perServingCode, into: perServing, env: env) == .filled(name: "Energy Shot"))
        #expect(perServing.basis == .perServing)
        #expect(perServing.energy == Format.field(12))
        #expect(perServing.basisServingAmount.isEmpty)
        #expect(perServing.validationErrors.contains("Enter the serving size."))
        perServing.basisServingAmount = "60"
        #expect(perServing.per100?.kcal == 20)
    }

    @Test func `unknown codes, lookup failures and codes of existing foods only add the barcode`() async throws {
        let env = environment()
        let unknown = FoodEditorModel(energyUnit: .kcal)
        #expect(await scan(ScanFlowTests.unknownCode, into: unknown, env: env) == .notFound)
        #expect(unknown.name.isEmpty && unknown.barcodes == [ScanFlowTests.unknownCode])

        let offline = environment(failure: .offline)
        let failed = FoodEditorModel(energyUnit: .kcal)
        #expect(await scan(ScanFlowTests.nutella, into: failed, env: offline) == .failed)
        #expect(failed.name.isEmpty && failed.barcodes == [ScanFlowTests.nutella])

        // Already on one of the user's foods: say which, fill nothing (saving asks to move the code).
        let foods = try #require(env.foods)
        let mine = FoodDetail(
            food: Food(name: "My spread", per100: Nutrients(kcal: 500, proteinG: 5, carbsG: 50, fatG: 30)),
            barcodes: [ScanFlowTests.nutella],
        )
        try foods.save(mine)
        let existing = FoodEditorModel(energyUnit: .kcal)
        #expect(await scan(ScanFlowTests.nutella, into: existing, env: env) == .existing(name: "My spread"))
        #expect(existing.name.isEmpty)

        // Editing an existing food never looks anything up.
        let editing = try FoodEditorModel(energyUnit: .kcal, editing: #require(try foods.detail(id: mine.food.id)))
        #expect(!editing.canFillFromLookup)
    }

    // MARK: Per-serving placeholders

    /// A per-serving placeholder as stored: one serving's values as per 100, with a 100 g stand-in serving.
    private func savePlaceholder(_ foods: FoodRepository) throws -> FoodDetail {
        let standIn = Serving(label: "1 bar", grams: 100)
        var food = Food(
            name: "Protein bar", source: .off, sourceID: "123",
            per100: Nutrients(kcal: 150, proteinG: 6, carbsG: 15, fatG: 6), dataQuality: .partialMacros,
        )
        food.perServingOnly = true
        food.defaultServingID = standIn.id
        food.notes = FoodDetail.perServingUnknownWeightNote
        return try foods.save(FoodDetail(food: food, servings: [standIn]))
    }

    @Test func `giving a placeholder's serving its real weight converts the food and what was logged`() throws {
        let env = environment()
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        let placeholder = try savePlaceholder(foods)
        let entry = try diary.log(
            food: placeholder.food, quantity: .servings(count: 1, serving: placeholder.servings[0].size),
            servingID: placeholder.servings[0].id, slotID: "breakfast", day: env.today,
        )

        let editor = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        #expect(editor.placeholderServingWeight == nil)
        editor.servings[0].amount = "30"
        #expect(editor.placeholderServingWeight == 30)
        let saved = try #require(try editor.save(to: foods))

        #expect(!saved.food.perServingOnly)
        #expect(!saved.isPerServingPlaceholder)
        #expect(abs(saved.food.kcal100 - 500) < 1e-9) // 150 kcal per 30 g
        #expect(abs(saved.food.proteinG100 - 20) < 1e-9) // 6 g per 30 g; macros 27 g per serving = 90 g per 100 g
        #expect(saved.food.notes == nil) // only the automatic note is dropped
        #expect(saved.food.dataQuality == .complete)
        let serving = try #require(saved.servings.first { $0.id == saved.food.defaultServingID })
        #expect(serving.grams == 30)
        let oneServing = Quantity.servings(count: 1, serving: serving.size).nutrients(per100: saved.food.per100)
        #expect(abs(oneServing.kcal - 150) < 1e-9)
        // The entry logged as 1 serving still is one serving.
        let stored = try #require(try diary.entry(id: entry.id))
        #expect(abs(stored.grams - 30) < 1e-9)
        #expect(stored.kcal == entry.kcal)
    }

    @Test func `editing other fields of a placeholder keeps it a placeholder`() throws {
        let env = environment()
        let foods = try #require(env.foods)
        let placeholder = try savePlaceholder(foods)
        let editor = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        editor.name = "Crunchy protein bar"
        editor.servings[0].label = "1 crunchy bar"
        #expect(editor.placeholderServingWeight == nil)
        let saved = try #require(try editor.save(to: foods))
        #expect(saved.food.perServingOnly)
        #expect(saved.isPerServingPlaceholder)
        #expect(saved.food.kcal100 == 150)
        #expect(saved.servings[0].grams == 100)

        // An implausible weight is refused with a message instead of saving wrong values.
        let tooLight = FoodEditorModel(energyUnit: .kcal, editing: saved)
        tooLight.servings[0].amount = "5" // 3000 kcal per 100 g
        #expect(throws: ServingWeightError.self) { try tooLight.save(to: foods) }
        #expect(try foods.food(id: placeholder.food.id)?.perServingOnly == true)
    }

    @Test func `one serving logs exactly the label values after saving in per-serving mode`() throws {
        let env = environment()
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        let placeholder = try savePlaceholder(foods)
        let entry = try diary.log(
            food: placeholder.food, quantity: .servings(count: 1, serving: placeholder.servings[0].size),
            servingID: placeholder.servings[0].id, slotID: "breakfast", day: env.today,
        )

        // The fields hold one serving's values; "Per serving" with the real weight of that serving.
        let editor = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        editor.basis = .perServing
        editor.basisServingAmount = "100" // the stand-in's weight: nothing learned yet
        #expect(editor.placeholderServingWeight == nil)
        editor.basisServingAmount = "30"
        #expect(editor.placeholderServingWeight == 30)
        let saved = try #require(try editor.save(to: foods))

        #expect(!saved.food.perServingOnly)
        #expect(!saved.isPerServingPlaceholder)
        #expect(abs(saved.food.kcal100 - 500) < 1e-9) // 150 kcal per 30 g
        #expect(abs(saved.food.proteinG100 - 20) < 1e-9)
        let serving = try #require(saved.servings.first { $0.id == saved.food.defaultServingID })
        #expect(serving.grams == 30)
        let oneServing = Quantity.servings(count: 1, serving: serving.size).nutrients(per100: saved.food.per100)
        #expect(abs(oneServing.kcal - 150) < 1e-9)
        #expect(abs(oneServing.proteinG - 6) < 1e-9)
        #expect(abs(oneServing.carbsG - 15) < 1e-9)
        #expect(abs(oneServing.fatG - 6) < 1e-9)
        // What was logged as 1 serving was rescaled once.
        let stored = try #require(try diary.entry(id: entry.id))
        #expect(abs(stored.grams - 30) < 1e-9)
        #expect(stored.kcal == entry.kcal)
        // Saving the converted food again changes nothing more.
        try FoodEditorModel(energyUnit: .kcal, editing: saved).save(to: foods)
        #expect(try abs(#require(try diary.entry(id: entry.id)).grams - 30) < 1e-9)
    }

    @Test func `a placeholder's edited serving row wins over a different per-serving size`() throws {
        let env = environment()
        let foods = try #require(env.foods)
        let placeholder = try savePlaceholder(foods)
        let editor = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        editor.basis = .perServing
        editor.basisServingAmount = "30" // the typed values are for 30 g …
        editor.servings[0].amount = "40" // … but one bar weighs 40 g
        #expect(editor.placeholderServingWeight == 40)
        let saved = try #require(try editor.save(to: foods))
        #expect(!saved.food.perServingOnly)
        #expect(abs(saved.food.kcal100 - 500) < 1e-9) // from the values per 30 g
        #expect(saved.servings[0].grams == 40)
    }

    @Test func `removing a placeholder's stand-in serving converts it with the per-serving size or blocks the save`() throws {
        let env = environment()
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        let placeholder = try savePlaceholder(foods)
        let standIn = placeholder.servings[0]
        let entry = try diary.log(
            food: placeholder.food, quantity: .servings(count: 1, serving: standIn.size),
            servingID: standIn.id, slotID: "breakfast", day: env.today,
        )

        // Without a weight, the serving can't just disappear: the save is blocked with a message.
        let blocked = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        blocked.servings.removeAll()
        #expect(blocked.placeholderServingWeight == nil)
        #expect(blocked.validationErrors.contains { $0.hasPrefix("These values are for one serving.") })
        #expect(!blocked.canSave)
        #expect(try blocked.save(to: foods) == nil)
        blocked.basis = .perServing // still no size
        #expect(blocked.validationErrors.contains("Enter the serving size."))
        #expect(!blocked.canSave)
        // A cleared serving name counts as removing the row.
        let cleared = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        cleared.servings[0].label = ""
        #expect(!cleared.canSave)
        #expect(try foods.food(id: placeholder.food.id)?.perServingOnly == true)

        // "Per serving" with the real weight converts it and keeps a default serving of that weight.
        let editor = FoodEditorModel(energyUnit: .kcal, editing: placeholder)
        editor.servings.removeAll()
        editor.basis = .perServing
        editor.basisServingAmount = "30"
        #expect(editor.placeholderServingWeight == 30)
        #expect(editor.canSave)
        let saved = try #require(try editor.save(to: foods))
        #expect(!saved.food.perServingOnly)
        #expect(!saved.isPerServingPlaceholder)
        #expect(abs(saved.food.kcal100 - 500) < 1e-9) // 150 kcal per 30 g
        #expect(saved.food.dataQuality == .complete)
        let serving = try #require(saved.servings.first { $0.id == saved.food.defaultServingID })
        #expect(serving.id == standIn.id)
        #expect(serving.label == standIn.label)
        #expect(serving.grams == 30)
        let stored = try #require(try foods.detail(id: placeholder.food.id))
        #expect(stored.food.defaultServingID == standIn.id)
        #expect(stored.servings.map(\.grams) == [30])
        let oneServing = Quantity.servings(count: 1, serving: serving.size).nutrients(per100: saved.food.per100)
        #expect(abs(oneServing.kcal - 150) < 1e-9)
        // What was logged as 1 serving still is one serving.
        let logged = try #require(try diary.entry(id: entry.id))
        #expect(abs(logged.grams - 30) < 1e-9)
        #expect(logged.kcal == entry.kcal)
    }
}
