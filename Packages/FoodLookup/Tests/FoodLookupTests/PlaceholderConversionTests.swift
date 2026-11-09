import Core
import FoodSources
import Foundation
import Persistence
import Testing
@testable import FoodLookup

struct PlaceholderConversionTests {
    /// A per-serving-only bar: 210 kcal, 10 g protein, 18 g carbs, 7 g fat per "1 bar" of unknown weight.
    private func placeholder(
        nutrients: Nutrients = Nutrients(kcal: 210, proteinG: 10, carbsG: 18, fatG: 7),
        missing: Set<FoodDraft.MandatoryNutrient> = [],
        serving: ServingSize? = nil,
    ) -> FoodDetail {
        FoodDetail(draft: FoodDraft(
            origin: .off, sourceID: "3850000000031", barcode: "3850000000031", name: "Protein bar",
            nutrients: nutrients, basis: .perServing, missingNutrients: missing,
            serving: serving, servingDescription: "1 bar",
        ))
    }

    @Test func `converts values to per 100 and gives the serving its weight`() throws {
        let detail = placeholder()
        #expect(detail.isPerServingPlaceholder)
        #expect(detail.food.dataQuality == .partialMacros)

        let converted = try detail.convertingPerServingPlaceholder(servingWeight: 40)
        #expect(!converted.isPerServingPlaceholder)
        #expect(!converted.food.perServingOnly)
        #expect(converted.food.per100.kcal == 525)
        #expect(converted.food.per100.proteinG == 25)
        #expect(converted.food.dataQuality == .complete)
        #expect(converted.food.notes == nil)
        let serving = try #require(converted.servings.first { $0.id == converted.food.defaultServingID })
        #expect(serving.label == "1 bar")
        #expect(serving.grams == 40)
        #expect(converted.food.id == detail.food.id)
    }

    @Test func `quality stays partial when values are missing, known or inferred from zeros`() throws {
        let energyOnly = placeholder(nutrients: Nutrients(kcal: 150, proteinG: 0, carbsG: 0, fatG: 0), missing: [.protein, .carbs, .fat])
        #expect(try energyOnly.convertingPerServingPlaceholder(servingWeight: 50, missing: [.protein]).food.dataQuality == .partialMacros)
        #expect(try energyOnly.convertingPerServingPlaceholder(servingWeight: 50).food.dataQuality == .partialMacros)
        // Known complete wins over a stored zero.
        #expect(try energyOnly.convertingPerServingPlaceholder(servingWeight: 50, missing: []).food.dataQuality == .complete)
    }

    @Test func `only the automatic per-serving note is cleared`() throws {
        let unusable = placeholder(serving: ServingSize(label: "1 tablet (0.5 g)", amount: 0.5))
        #expect(FoodDetail.isPerServingPlaceholderNote(unusable.food.notes))
        #expect(try unusable.convertingPerServingPlaceholder(servingWeight: 40).food.notes == nil)

        var mine = placeholder()
        mine.food.notes = "Bought at Konzum"
        #expect(try mine.convertingPerServingPlaceholder(servingWeight: 40).food.notes == "Bought at Konzum")
    }

    @Test func `implausible weights are rejected`() {
        let detail = placeholder()
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: 0) }
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: -.infinity) }
        #expect(throws: ServingWeightError.implausibleEnergy(kcalPer100: 2100)) {
            try detail.convertingPerServingPlaceholder(servingWeight: 10)
        }
        // 30 g of carbs in a 20 g serving: 150 g per 100 g, though only 300 kcal.
        let gummy = placeholder(nutrients: Nutrients(kcal: 60, proteinG: 0, carbsG: 30, fatG: 0))
        #expect(throws: ServingWeightError.implausibleMacros(gramsPer100: 150)) {
            try gummy.convertingPerServingPlaceholder(servingWeight: 20)
        }
    }
}
