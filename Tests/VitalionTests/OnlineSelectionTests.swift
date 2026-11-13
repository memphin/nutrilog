import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Testing
@testable import Vitalion

private func draft(
    _ origin: FoodDraft.Origin,
    _ id: String,
    _ name: String,
    brand: String? = nil,
    barcode: String? = nil,
    kcal: Double = 100,
) -> FoodDraft {
    FoodDraft(
        origin: origin, sourceID: id, barcode: barcode, name: name, brand: brand,
        nutrients: Nutrients(kcal: kcal, proteinG: 5, carbsG: 10, fatG: 3),
    )
}

private func hit(_ code: String, _ name: String, brand: String? = nil) -> OFFSearchHit {
    OFFSearchHit(code: code, name: name, brand: brand)
}

// MARK: - Selecting a result

@MainActor
struct OnlineSelectionTests {
    @Test func `selecting a result stores a local copy that local search finds`() async throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        let search = try #require(env.search)
        let model = OnlineSearchModel()
        let result = OnlineFoodResult(draft(.usda, "2345678", "ZDENKA CHEESE TRIANGLES", brand: "VINDIJA", kcal: 260))

        guard case let .open(detail) = try await model.select(result, in: foods, lookup: nil) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(detail.food.source == .usda)
        #expect(detail.food.sourceID == "2345678")
        #expect(detail.food.name == "Zdenka Cheese Triangles")
        #expect(detail.food.brand == "Vindija")
        #expect(detail.food.per100.kcal == 260)

        let local = try search.search("zdenka")
        #expect(local.first?.id == "food:\(detail.food.id)")
        #expect(local.first?.source == .usda)

        // Idempotent: picking it again reuses the copy.
        guard case let .open(again) = try await model.select(result, in: foods, lookup: nil) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(again.food.id == detail.food.id)
    }

    @Test func `a per-serving-only result asks for the serving weight first`() async throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        var bar = draft(.off, "3850000000031", "Protein bar", barcode: "3850000000031", kcal: 210)
        bar.basis = .perServing
        bar.servingDescription = "1 bar"

        guard case let .askServingWeight(pending) = try await OnlineSearchModel().select(OnlineFoodResult(bar), in: foods, lookup: nil)
        else {
            Issue.record("expected the serving-weight prompt")
            return
        }
        #expect(pending.detail.isPerServingPlaceholder)

        // Same conversion as the scan flow; quality follows the stored copy (nothing stored as 0 → complete).
        let converted = try pending.detail.convertingPerServingPlaceholder(servingWeight: 40)
        let saved = try foods.save(converted)
        #expect(!saved.isPerServingPlaceholder)
        #expect(saved.food.per100.kcal == 525) // 210 kcal per 40 g bar
        #expect(saved.food.dataQuality == .complete)
        #expect(saved.food.notes == nil)
        #expect(saved.servings.first { $0.id == saved.food.defaultServingID }?.grams == 40)
        #expect(saved.food.id == pending.detail.food.id)

        // Picked again later: the converted copy opens directly.
        guard case .open = try await OnlineSearchModel().select(OnlineFoodResult(bar), in: foods, lookup: nil) else {
            Issue.record("expected the converted food to open")
            return
        }
    }

    @Test func `a skipped serving weight still logs one serving correctly`() async throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        var bar = draft(.off, "3850000000048", "Energy bar", barcode: "3850000000048", kcal: 210)
        bar.basis = .perServing
        bar.servingDescription = "1 bar"
        guard case let .askServingWeight(pending) = try await OnlineSearchModel().select(OnlineFoodResult(bar), in: foods, lookup: nil)
        else {
            Issue.record("expected the serving-weight prompt")
            return
        }

        // "Skip" opens the quantity sheet with the placeholder: servings only, 1 serving prefilled.
        let detail = pending.detail
        #expect(!QuantitySheet.offersBaseUnit(detail))
        let serving = try #require(detail.servings.first { $0.id == detail.food.defaultServingID })
        let initial = QuantitySheet.initialLogQuantity(detail)
        #expect(initial.quantity == .servings(count: 1, serving: serving.size))
        #expect(QuantitySheet.quantity(amountText: "100", unitChoice: "base", detail: detail) == nil)

        let entry = try diary.log(
            food: detail.food, quantity: initial.quantity, servingID: serving.id,
            slotID: "breakfast", day: env.today,
        )
        #expect(entry.nutrients.kcal == 210)
        #expect(entry.nutrients.proteinG == 5)
        #expect(entry.servingLabel?.contains("1 bar") == true)
    }

    @Test func `the prompt's conversion rejects implausible weights`() {
        var gummy = draft(.off, "2", "Gummies", kcal: 60)
        gummy.basis = .perServing
        gummy.nutrients = Nutrients(kcal: 60, proteinG: 0, carbsG: 30, fatG: 0)
        let detail = FoodDetail(draft: gummy)
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: 0) }
        // 30 g of carbs in a 20 g serving = 150 g per 100 g, though only 300 kcal per 100.
        #expect(throws: ServingWeightError.implausibleMacros(gramsPer100: 150)) {
            try detail.convertingPerServingPlaceholder(servingWeight: 20)
        }
    }

    @Test func `OFF rows link to the product page; USDA rows don't`() {
        var off = draft(.off, "3017620422003", "Nutella")
        off.productURL = URL(string: "https://world.openfoodfacts.org/product/3017620422003")
        var usda = draft(.usda, "1", "Nutella")
        usda.productURL = URL(string: "https://fdc.nal.usda.gov/food-details/1")
        #expect(OnlineFoodResult(off).offProductURL?.absoluteString == "https://world.openfoodfacts.org/product/3017620422003")
        #expect(OnlineFoodResult(usda).offProductURL == nil)
        #expect(OnlineFoodResult(hit("3017620422003", "Nutella")).offProductURL?.absoluteString
            == "https://world.openfoodfacts.org/product/3017620422003")
    }

    @Test func `picking an Open Food Facts result fetches the product by barcode and saves it`() async throws {
        let client = StubOpenFoodFactsClient(products: [OFFProduct(
            code: "3850102111961", productName: "DORINA MLIJEČNA", brands: "Kraš",
            nutriments: ["energy-kcal_100g": 540, "proteins_100g": 7, "carbohydrates_100g": 56, "fat_100g": 31],
        )])
        let env = AppEnvironment.preview(openFoodFacts: client)
        let foods = try #require(env.foods)
        let model = OnlineSearchModel()
        let result = OnlineFoodResult(hit("3850102111961", "Dorina Mliječna", brand: "Kraš"))

        guard case let .open(detail) = try await model.select(result, in: foods, lookup: env.barcodeLookup) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(detail.food.source == .off)
        #expect(detail.food.name == "Dorina Mliječna")
        #expect(detail.food.per100.kcal == 540)
        #expect(model.fetchingResultID == nil)
        #expect(client.requests == ["3850102111961"])

        // Picked again: the saved copy opens without asking OFF.
        guard case let .open(again) = try await model.select(result, in: foods, lookup: env.barcodeLookup) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(again.food.id == detail.food.id)
        #expect(client.requests == ["3850102111961"])
    }

    @Test(arguments: [
        (OpenFoodFactsError?.none, OnlineSearchModel.SelectionError.productGone),
        (.offline, .offline),
        (.rateLimited, .unavailable),
        (.timedOut, .unavailable),
    ])
    func `a failed product fetch says why`(failure: OpenFoodFactsError?, expected: OnlineSearchModel.SelectionError) async throws {
        let env = AppEnvironment.preview(openFoodFacts: StubOpenFoodFactsClient(failure: failure))
        let foods = try #require(env.foods)
        let model = OnlineSearchModel()
        await #expect(throws: expected) {
            try await model.select(OnlineFoodResult(hit("3850102111961", "Dorina")), in: foods, lookup: env.barcodeLookup)
        }
        #expect(model.fetchingResultID == nil)
    }
}
