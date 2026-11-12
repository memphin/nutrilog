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

    @Test func `notes are recognized whatever language and number format they were stored in`() {
        let tablet = ServingSize(label: "1 tablet", amount: 0.5)
        let en = FoodDetail.perServingUnusableWeightNote(tablet, isLiquid: false, locale: Locale(identifier: "en_US"))
        let hr = FoodDetail.perServingUnusableWeightNote(tablet, isLiquid: true, locale: Locale(identifier: "hr_HR"))
        #expect(en.contains("(0.5 g)"))
        #expect(hr.contains("(0,5 ml)"))
        #expect(FoodDetail.isPerServingPlaceholderNote(en))
        #expect(FoodDetail.isPerServingPlaceholderNote(hr))
        #expect(FoodDetail.isPerServingPlaceholderNote(FoodDetail.perServingUnknownWeightNote))
        // Stored in English by an earlier version.
        #expect(FoodDetail.isPerServingPlaceholderNote(
            "Nutrition per serving; the serving weight is unknown, so 1 serving is counted as 100 g/ml.",
        ))
        #expect(!FoodDetail.isPerServingPlaceholderNote("Nutrition per serving"))
        #expect(!FoodDetail.isPerServingPlaceholderNote(nil))
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

    @Test func `absurd weights are rejected before converting`() {
        let detail = placeholder()
        for weight in [0.000_000_000_000_000_01, 0.09, 100_000.5, 1e19, Double.greatestFiniteMagnitude] {
            #expect(throws: ServingWeightError.outOfRange) { try detail.convertingPerServingPlaceholder(servingWeight: weight) }
        }
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: .nan) }
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: .infinity) }
        let message = ServingWeightError.outOfRange.errorDescription ?? ""
        #expect(message.hasPrefix("Enter a weight between ")) // numbers follow the device locale
        // Bounds are inclusive; 0.1 g of a 210 kcal bar is implausible, but for the energy, not the range.
        #expect(throws: ServingWeightError.implausibleEnergy(kcalPer100: 210_000)) {
            try detail.convertingPerServingPlaceholder(servingWeight: 0.1)
        }
        let water = placeholder(nutrients: Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0))
        #expect((try? water.convertingPerServingPlaceholder(servingWeight: 100_000)) != nil)
    }

    @Test func `error messages never trap, whatever the value`() {
        let values: [Double] = [2100, 1e19, -1e19, .greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        for value in values {
            #expect(ServingWeightError.implausibleEnergy(kcalPer100: value).errorDescription?.isEmpty == false)
            #expect(ServingWeightError.implausibleMacros(gramsPer100: value).errorDescription?.isEmpty == false)
        }
        #expect(ServingWeightError.implausibleEnergy(kcalPer100: 2100).errorDescription?.contains("kcal per 100") == true)
        #expect(ServingWeightError.implausibleEnergy(kcalPer100: .infinity).errorDescription?.contains("∞ kcal") == true)
    }

    @Test func `numbers in error messages follow the locale`() {
        #expect(ServingWeightError.number(0.1, fractionDigits: 1, locale: Locale(identifier: "en_US")) == "0.1")
        #expect(ServingWeightError.number(0.1, fractionDigits: 1, locale: Locale(identifier: "hr_HR")) == "0,1")
        #expect(ServingWeightError.number(100_000, locale: Locale(identifier: "en_US")) == "100,000")
        #expect(ServingWeightError.number(100_000, locale: Locale(identifier: "hr_HR")) == "100.000")
        #expect(ServingWeightError.number(.infinity, locale: Locale(identifier: "hr_HR")) == "∞")
    }
}
