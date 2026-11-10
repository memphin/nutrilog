import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Testing
@testable import Nutrilog

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
}
