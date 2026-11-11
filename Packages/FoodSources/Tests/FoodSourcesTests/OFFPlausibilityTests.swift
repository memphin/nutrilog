import Core
import Foundation
import Testing
@testable import FoodSources

/// Impossible values, energy typos, serving units and basis choice in the mapper.
struct OFFPlausibilityTests {
    private func map(
        _ nutriments: [String: Double],
        servingSize: String? = nil,
        servingQuantity: Double? = nil,
        servingQuantityUnit: String? = nil,
    ) -> FoodDraft {
        OFFFoodMapper.map(OFFProduct(
            code: "3850000000005",
            productName: "Test",
            servingSize: servingSize,
            servingQuantity: servingQuantity,
            servingQuantityUnit: servingQuantityUnit,
            nutriments: nutriments,
        ))
    }

    private static let macros: [String: Double] = ["proteins_100g": 6, "carbohydrates_100g": 57, "fat_100g": 31]

    // MARK: - Energy

    @Test func `kcal equal to kJ means the kJ figure was typed as kcal`() {
        let nutriments = Self.macros.merging(["energy-kcal_100g": 2252, "energy-kj_100g": 2252]) { $1 }
        let draft = map(nutriments)
        let expected = 2252 / 4.184
        #expect(isClose(draft.nutrients.kcal, expected))
        #expect(draft.dataQuality == .complete)
    }

    @Test func `energy helper keeps consistent kcal and falls back to kJ`() {
        #expect(NutrientValues.energy(kcal: 539, kJ: 2252) == 539)
        #expect(isClose(NutrientValues.energy(kcal: nil, kJ: 1046), 250))
        #expect(NutrientValues.energy(kcal: 0, kJ: 0) == 0)
        #expect(NutrientValues.energy(kcal: 42, kJ: nil) == 42)
        #expect(NutrientValues.energy(kcal: nil, kJ: nil) == nil)
    }

    @Test func `more than 900 kcal per 100 g counts as missing energy`() {
        let draft = map(Self.macros.merging(["energy-kcal_100g": 2252]) { $1 })
        #expect(draft.missingNutrients == [.energy])
        #expect(draft.dataQuality == .partialMacros)
        #expect(draft.nutrients.kcal == 0)
    }

    @Test func `pure fat at 900 kcal is still plausible`() {
        let draft = map(["energy-kcal_100g": 900, "proteins_100g": 0, "carbohydrates_100g": 0, "fat_100g": 100])
        #expect(draft.dataQuality == .complete)
    }

    // MARK: - Macros & salt

    @Test func `a macro above 100 g per 100 g counts as missing`() {
        let draft = map(["energy-kcal_100g": 400, "proteins_100g": 150, "carbohydrates_100g": 20, "fat_100g": 5])
        #expect(draft.missingNutrients == [.protein])
        #expect(draft.dataQuality == .partialMacros)
    }

    @Test func `macros summing above 105 g are all dropped`() {
        let draft = map(["energy-kcal_100g": 400, "proteins_100g": 40, "carbohydrates_100g": 50, "fat_100g": 30])
        #expect(draft.missingNutrients == [.protein, .carbs, .fat])
        #expect(draft.dataQuality != .complete)
        #expect(draft.nutrients.proteinG == 0)
    }

    @Test func `salt above 100 g per 100 g is dropped`() {
        let draft = map(Self.macros.merging(["energy-kcal_100g": 500, "salt_100g": 250]) { $1 })
        #expect(draft.nutrients.sodiumMg == nil)
        #expect(draft.dataQuality == .complete) // sodium is optional
    }

    @Test func `pure salt is plausible`() {
        let draft = map(["energy-kcal_100g": 0, "proteins_100g": 0, "carbohydrates_100g": 0, "fat_100g": 0, "salt_100g": 100])
        #expect(isClose(draft.nutrients.sodiumMg, 40000))
    }

    @Test func `caffeine above 5 g per 100 g is dropped`() {
        let draft = map(Self.macros.merging(["energy-kcal_100g": 500, "caffeine_100g": 32]) { $1 })
        #expect(draft.nutrients.caffeineMg == nil) // 32 mg typed into the gram field
        #expect(draft.dataQuality == .complete) // caffeine is optional
    }

    @Test func `instant coffee powder caffeine is plausible`() {
        let draft = map(["energy-kcal_100g": 350, "proteins_100g": 12, "carbohydrates_100g": 75, "fat_100g": 0.5,
                         "caffeine_100g": 4])
        #expect(isClose(draft.nutrients.caffeineMg, 4000))
    }

    // MARK: - Servings

    private static let tabletServing: [String: Double] = [
        "energy-kcal_serving": 10, "proteins_serving": 0, "carbohydrates_serving": 2.4, "fat_serving": 0,
    ]

    @Test func `servings under 1 g are not scaled to 100 g`() {
        let draft = map(Self.tabletServing, servingSize: "1 tablet (500 mg)")
        #expect(draft.basis == .perServing)
        #expect(draft.dataQuality == .partialMacros)
        #expect(draft.nutrients.kcal == 10)
        #expect(draft.serving?.amount == 0.5)
    }

    @Test func `serving_quantity in g or ml or without a unit is used as is`() {
        for unit in [nil, "g", "ml", "G"] {
            let draft = map(Self.tabletServing, servingSize: "1 bar (40 g)", servingQuantity: 20, servingQuantityUnit: unit)
            #expect(draft.serving?.amount == 20, "\(unit ?? "nil")")
        }
    }

    @Test func `serving_quantity in another known unit is converted`() {
        let draft = map(["energy-kcal_serving": 139], servingQuantity: 33, servingQuantityUnit: "cl")
        #expect(draft.serving?.amount == 330)
        let expected = 139 / 3.3
        #expect(isClose(draft.nutrients.kcal, expected))
    }

    @Test func `serving_quantity in an unknown unit falls back to serving_size`() {
        let draft = map(Self.tabletServing, servingSize: "1 bar (40 g)", servingQuantity: 1, servingQuantityUnit: "portion")
        #expect(draft.serving?.amount == 40)
        #expect(draft.basis == .per100)
        #expect(isClose(draft.nutrients.kcal, 25))
    }

    @Test(arguments: [1e19, 100_000.5, Double.infinity, Double.nan, -5, 0])
    func `absurd serving_quantity counts as no serving`(quantity: Double) {
        let draft = map(Self.tabletServing, servingQuantity: quantity)
        #expect(draft.serving == nil)
        #expect(draft.basis == .perServing)
        #expect(draft.nutrients.kcal == 10) // not scaled by an absurd weight
    }

    @Test func `absurd serving_quantity falls back to a usable serving_size`() {
        let draft = map(Self.tabletServing, servingSize: "1 bar (40 g)", servingQuantity: 1e19)
        #expect(draft.serving == ServingSize(label: "1 bar (40 g)", amount: 40))
    }

    @Test func `absurd amounts after conversion or parsing count as no serving`() {
        #expect(map(Self.tabletServing, servingQuantity: 200, servingQuantityUnit: "kg").serving == nil)
        #expect(map(Self.tabletServing, servingSize: "1 pallet (500 kg)").serving == nil)
        // The 100 000 g limit itself is still a serving.
        #expect(map(Self.tabletServing, servingQuantity: 100_000).serving?.amount == 100_000)
    }

    @Test func `serving_quantity 1e19 in an OFF payload maps without crashing and without a serving`() throws {
        let json = #"""
        {"status": 1, "code": "3850000000005", "product": {"code": "3850000000005", "product_name": "Bad serving",
         "serving_quantity": 1e19, "serving_quantity_unit": "g",
         "nutriments": {"energy-kcal_serving": 120, "proteins_serving": 3, "carbohydrates_serving": 20, "fat_serving": 2}}}
        """#
        let response = try #require(OFFProductResponse.parse(Data(json.utf8)))
        let product = try #require(response.product)
        #expect(product.servingQuantity == 1e19)
        let draft = OFFFoodMapper.map(product)
        #expect(draft.serving == nil)
        #expect(draft.basis == .perServing)
        #expect(draft.nutrients.kcal == 120)
    }

    // MARK: - Basis choice

    private static let energyPer100WithServingMacros: [String: Double] = [
        "energy-kcal_100g": 400,
        "energy-kcal_serving": 120, "proteins_serving": 10, "carbohydrates_serving": 12, "fat_serving": 4,
    ]

    @Test func `per-serving macros fill per-100 gaps when the serving weight is known`() {
        let draft = map(Self.energyPer100WithServingMacros, servingSize: "1 bar (30 g)", servingQuantity: 30)
        #expect(draft.basis == .per100)
        #expect(draft.dataQuality == .complete)
        #expect(draft.nutrients.kcal == 400)
        #expect(isClose(draft.nutrients.proteinG, 33.333))
        #expect(isClose(draft.nutrients.carbsG, 40))
    }

    @Test func `per-serving basis wins when it leaves fewer nutrients missing`() {
        let draft = map(Self.energyPer100WithServingMacros, servingSize: "1 bar")
        #expect(draft.basis == .perServing)
        #expect(draft.missingNutrients.isEmpty)
        #expect(draft.nutrients.kcal == 120)
        #expect(draft.nutrients.proteinG == 10)
        #expect(draft.dataQuality == .partialMacros)
    }

    @Test func `per 100 wins a tie`() {
        let draft = map(["energy-kcal_100g": 400, "energy-kcal_serving": 120], servingSize: "1 bar")
        #expect(draft.basis == .per100)
        #expect(draft.dataQuality == .energyOnly)
    }
}
