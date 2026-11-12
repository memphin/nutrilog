import Core
import FoodSources
import Foundation
import Persistence
import Testing
@testable import FoodLookup

struct RemoteFoodCopyTests {
    func draft(
        name: String? = "Nutella",
        basis: FoodDraft.NutrientBasis = .per100,
        missing: Set<FoodDraft.MandatoryNutrient> = [],
        serving: ServingSize? = ServingSize(label: "1 portion (15 g)", amount: 15),
        servingDescription: String? = "1 portion (15 g)",
    ) -> FoodDraft {
        FoodDraft(
            origin: .off,
            sourceID: "3017620422003",
            barcode: "3017620422003",
            name: name,
            nameLocal: "Nutella HR",
            brand: "Ferrero",
            nutrients: Nutrients(kcal: 539, proteinG: 6.3, carbsG: 57.5, fatG: 30.9, sugarG: 56.3, sodiumMg: 42),
            basis: basis,
            missingNutrients: missing,
            isLiquid: false,
            serving: serving,
            servingDescription: servingDescription,
            imageURL: URL(string: "https://images.openfoodfacts.org/x.jpg"),
            nutriscore: "e",
        )
    }

    @Test func `quality and source raw values match`() {
        for quality in FoodDataQuality.allCases {
            #expect(DataQuality(quality).rawValue == quality.rawValue)
        }
        #expect(FoodSource(.off) == .off)
        #expect(FoodSource(.usda) == .usda)
    }

    @Test func `caffeine is carried into the copy`() {
        var energyDrink = draft(name: "Energy")
        energyDrink.nutrients.caffeineMg = 32
        #expect(FoodDetail(draft: energyDrink).food.caffeineMg100 == 32)
        #expect(FoodDetail(draft: draft()).food.caffeineMg100 == nil)
    }

    @Test func `per 100 draft becomes a food with its serving`() {
        let detail = FoodDetail(draft: draft())
        let food = detail.food
        #expect(food.name == "Nutella")
        #expect(food.nameLocal == "Nutella HR")
        #expect(food.brand == "Ferrero")
        #expect(food.source == .off)
        #expect(food.sourceID == "3017620422003")
        #expect(food.per100 == Nutrients(kcal: 539, proteinG: 6.3, carbsG: 57.5, fatG: 30.9, sugarG: 56.3, sodiumMg: 42))
        #expect(food.imageURL == "https://images.openfoodfacts.org/x.jpg")
        #expect(food.nutriscore == "e")
        #expect(food.dataQuality == .complete)
        #expect(food.notes == nil)
        #expect(detail.servings.map(\.label) == ["1 portion (15 g)"])
        #expect(detail.servings.map(\.grams) == [15])
        #expect(food.defaultServingID == detail.servings.first?.id)
        #expect(detail.barcodes == ["3017620422003"])
    }

    @Test func `per 100 draft without serving has no servings`() {
        let detail = FoodDetail(draft: draft(serving: nil))
        #expect(detail.servings.isEmpty)
        #expect(detail.food.defaultServingID == nil)
    }

    @Test func `per serving draft gets a stand in serving of 100`() throws {
        let detail = FoodDetail(draft: draft(basis: .perServing, serving: nil, servingDescription: "1 bar"))
        #expect(detail.food.dataQuality == .partialMacros)
        #expect(detail.food.kcal100 == 539) // per serving, counted as 100 g
        #expect(detail.food.notes == FoodDetail.perServingUnknownWeightNote)
        #expect(detail.food.perServingOnly)
        #expect(detail.isPerServingPlaceholder)
        let serving = try #require(detail.servings.first)
        #expect(serving.label == "1 bar")
        #expect(serving.grams == 100)
        #expect(detail.food.defaultServingID == serving.id)
        #expect(FoodDetail(draft: draft(basis: .perServing, serving: nil, servingDescription: nil)).servings.first?.label
            == FoodDetail.perServingFallbackLabel)
    }

    @Test func `per serving draft with an unusable serving weight says so`() {
        let tablet = ServingSize(label: "1 tablet (500 mg)", amount: 0.5)
        let detail = FoodDetail(draft: draft(basis: .perServing, serving: tablet, servingDescription: "1 tablet (500 mg)"))
        #expect(detail.food.notes == FoodDetail.perServingUnusableWeightNote(tablet, isLiquid: false))
        #expect(detail.food.notes?.contains("(\(NumberFormatting.compact(0.5, locale: .current)) g)") == true)
        #expect(detail.isPerServingPlaceholder)
        #expect(detail.servings.first?.label == "1 tablet (500 mg)")
    }

    @Test(arguments: [1e19, 100_000.5, Double.infinity, Double.nan])
    func `an absurd serving weight in a draft counts as none`(amount: Double) {
        let absurd = ServingSize(label: "1 bar", amount: amount)
        let per100 = FoodDetail(draft: draft(serving: absurd))
        #expect(per100.servings.isEmpty)
        let perServing = FoodDetail(draft: draft(basis: .perServing, serving: absurd, servingDescription: "1 bar"))
        #expect(perServing.food.notes == FoodDetail.perServingUnknownWeightNote)
        #expect(perServing.servings.first?.grams == 100)
    }

    @Test func `per 100 draft is not a per serving placeholder`() {
        let detail = FoodDetail(draft: draft())
        #expect(!detail.food.perServingOnly)
        #expect(!detail.isPerServingPlaceholder)
    }

    @Test func `per serving marker survives a save`() throws {
        let foods = try FoodRepository(AppDatabase.inMemory())
        let saved = try foods.saveRemoteCopy(draft(basis: .perServing, serving: nil))
        let reread = try #require(try foods.detail(id: saved.food.id))
        #expect(reread.food.perServingOnly)
        #expect(reread.isPerServingPlaceholder)
    }

    @Test func `missing macros keep the partial quality`() {
        #expect(FoodDetail(draft: draft(missing: [.fat])).food.dataQuality == .partialMacros)
        #expect(FoodDetail(draft: draft(missing: [.protein, .carbs, .fat])).food.dataQuality == .energyOnly)
    }

    @Test func `name falls back to brand then source id`() {
        #expect(FoodDetail(draft: draft(name: nil)).food.name == "Ferrero")
        #expect(FoodDetail(draft: draft(name: "  ")).food.name == "Ferrero")
        var noBrand = draft(name: nil)
        noBrand.brand = nil
        #expect(FoodDetail(draft: noBrand).food.name == "3017620422003")
    }

    @Test func `save remote copy is idempotent by source id and barcode`() throws {
        let db = try AppDatabase.inMemory()
        let foods = FoodRepository(db)
        let first = try foods.saveRemoteCopy(draft())
        #expect(try foods.saveRemoteCopy(draft()).food.id == first.food.id)

        var otherBarcode = draft()
        otherBarcode.barcode = nil
        #expect(try foods.saveRemoteCopy(otherBarcode).food.id == first.food.id) // same source + source ID

        var usda = FoodDraft(origin: .usda, sourceID: "171705", name: "Oats", nutrients: .zero)
        usda.barcode = "3017620422003"
        #expect(try foods.saveRemoteCopy(usda).food.id == first.food.id) // the barcode's food wins
        usda.barcode = nil
        let oats = try foods.saveRemoteCopy(usda)
        #expect(oats.food.id != first.food.id)
        #expect(oats.food.source == .usda)
        #expect(try foods.saveRemoteCopy(usda).food.id == oats.food.id)
    }
}
