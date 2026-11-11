import Core
import Foundation
import Testing
@testable import FoodSources

/// Nutrient-ID mapping over trimmed real FDC search responses (captured with `DEMO_KEY`) and hand-built edge cases.
struct FDCFoodMapperTests {
    private func drafts(_ name: String) throws -> [FoodDraft] {
        let response = try #require(FDCSearchResponse.parse(Fixture.data(name, in: "USDA")))
        return response.foods.compactMap(FDCFoodMapper.map)
    }

    private func draft(_ name: String, id: String) throws -> FoodDraft {
        try #require(drafts(name).first { $0.sourceID == id }, "\(name) has no food \(id)")
    }

    // MARK: - Data types

    @Test func `foundation: energy from Atwater specific factors, all macros and optionals`() throws {
        let apple = try draft("search_foundation", id: "1750340")
        #expect(apple.origin == .usda)
        #expect(apple.name == "Apples, fuji, with skin, raw")
        #expect(apple.basis == .per100)
        #expect(apple.dataQuality == .complete)
        #expect(isClose(apple.nutrients.kcal, 58.2)) // 2048, not 2047 (64.7)
        #expect(isClose(apple.nutrients.proteinG, 0.148, tolerance: 0.0001))
        #expect(isClose(apple.nutrients.fatG, 0.162, tolerance: 0.0001))
        #expect(isClose(apple.nutrients.carbsG, 15.7)) // 1005, not 1050 (15.4)
        #expect(isClose(apple.nutrients.fiberG, 2.08))
        #expect(isClose(apple.nutrients.sugarG, 13.3))
        #expect(apple.nutrients.satFatG == nil)
        #expect(isClose(apple.nutrients.sodiumMg, 1.01))
        #expect(!apple.isLiquid)
        #expect(apple.serving == nil)
        #expect(apple.brand == nil)
        #expect(apple.barcode == nil)
        #expect(apple.productURL == URL(string: "https://fdc.nal.usda.gov/food-details/1750340/nutrients"))
    }

    @Test func `sr Legacy: 1008 kcal wins over the 1062 kJ listed first`() throws {
        let croissant = try draft("search_sr_legacy", id: "174988")
        #expect(croissant.name == "Croissants, apple")
        #expect(croissant.dataQuality == .complete)
        #expect(croissant.nutrients.kcal == 254)
        #expect(croissant.nutrients.proteinG == 7.4)
        #expect(croissant.nutrients.fatG == 8.7)
        #expect(croissant.nutrients.carbsG == 37.1)
        #expect(croissant.nutrients.fiberG == 2.5)
        #expect(croissant.nutrients.sugarG == nil)
        #expect(croissant.nutrients.satFatG == 4.99)
        #expect(croissant.nutrients.sodiumMg == 274)
    }

    @Test func `branded solid: per 100 g, serving from servingSize and household text, UPC as EAN-13`() throws {
        let apple = try draft("search_branded", id: "454004")
        #expect(apple.name == "APPLE")
        #expect(apple.brand == "TREECRISP 2 GO") // brandOwner when there is no brandName
        #expect(apple.dataQuality == .complete)
        #expect(apple.nutrients.kcal == 52)
        #expect(apple.nutrients.proteinG == 0)
        #expect(apple.nutrients.fatG == 0.65)
        #expect(apple.nutrients.carbsG == 14.3)
        #expect(apple.nutrients.sugarG == 10.4)
        #expect(apple.nutrients.satFatG == 0)
        #expect(apple.nutrients.sodiumMg == 0)
        #expect(!apple.isLiquid)
        #expect(apple.serving == ServingSize(label: "5.5 ONZ", amount: 154))
        #expect(apple.servingDescription == "5.5 ONZ")
        #expect(apple.barcode == Barcode.normalize("867824000001"))
        #expect(apple.barcode?.count == 13)
        #expect(apple.ingredientsText == "CRISP APPLE.")
    }

    @Test(arguments: ["2117388", "2501185"])
    func `branded liquid: serving in ml or MLT makes the food liquid`(id: String) throws {
        let drink = try draft("search_branded", id: id)
        #expect(drink.isLiquid)
        #expect(drink.baseUnit == .milliliters)
        #expect(drink.serving?.amount == 240)
        #expect(drink.dataQuality == .complete)
    }

    @Test func `branded milk keeps brand name, package size and optional nutrients`() throws {
        let milk = try draft("search_branded", id: "2501185")
        #expect(milk.serving?.label == "1 cup")
        #expect(milk.nutrients.kcal == 62)
        #expect(milk.nutrients.satFatG == 2.08)
        #expect(milk.nutrients.sodiumMg == 52)
        #expect(milk.packageDescription == "HALF GALLON/1.89 L")
    }

    @Test func `mixed search keeps FDC order and every data type`() throws {
        let foods = try drafts("search_mixed")
        #expect(foods.map(\.sourceID) == ["2095236", "1750341", "175032"])
        #expect(foods.allSatisfy { $0.origin == .usda && $0.dataQuality == .complete })
        let cheddar = try #require(foods.first)
        #expect(cheddar.brand == "AMISH CLASSICS")
        #expect(cheddar.nutrients.kcal == 432)
        #expect(cheddar.nutrients.sodiumMg == 686)
        #expect(cheddar.nutrients.satFatG == 21.4)
    }

    // MARK: - Units and fallbacks

    @Test func `kJ energy, sodium in g and saturated fat in mg are converted`() throws {
        let bar = try draft("search_edge_cases", id: "9000001")
        #expect(isClose(bar.nutrients.kcal, 400))
        #expect(isClose(bar.nutrients.sodiumMg, 400))
        #expect(isClose(bar.nutrients.satFatG, 1.5))
        #expect(bar.serving == ServingSize(label: "40 g", amount: 40)) // "GRM", no household text
        #expect(bar.barcode == nil) // gtinUpc isn't a valid code
        #expect(bar.dataQuality == .complete)
    }

    @Test func `nutrient numbers stand in for missing ids; string values parse; unknown units are missing`() throws {
        let food = try draft("search_edge_cases", id: "9000002")
        #expect(isClose(food.nutrients.kcal, 100)) // 268 = 1062, kJ
        #expect(food.nutrients.proteinG == 12.5)
        #expect(food.nutrients.fatG == 3)
        #expect(food.nutrients.carbsG == 0)
        #expect(food.missingNutrients.isEmpty)
        #expect(food.nutrients.sodiumMg == nil) // "IU"
    }

    @Test func `fallback ids: Atwater general, fat NLEA, carbs by summation, AOAC fiber, Sugars Total`() throws {
        let food = try draft("search_edge_cases", id: "9000004")
        #expect(food.nutrients.kcal == 120)
        #expect(food.nutrients.fatG == 2.5)
        #expect(food.nutrients.carbsG == 20)
        #expect(food.nutrients.fiberG == 3)
        #expect(food.nutrients.sugarG == 1.2)
        #expect(food.nutrients.sodiumMg == 5)
        #expect(food.dataQuality == .complete)
    }

    @Test func `energy-only food; a serving of 0 ml still marks it liquid but adds no serving`() throws {
        let food = try draft("search_edge_cases", id: "9000005")
        #expect(food.dataQuality == .energyOnly)
        #expect(food.missingNutrients == [.protein, .carbs, .fat])
        #expect(food.serving == nil)
        #expect(food.isLiquid)
    }

    @Test func `impossible, negative and null values count as missing`() throws {
        let food = try draft("search_edge_cases", id: "9000006")
        #expect(food.missingNutrients == [.energy, .protein, .carbs])
        #expect(food.nutrients.kcal == 0)
        #expect(food.nutrients.fatG == 10)
        #expect(food.dataQuality == .partialMacros)
    }

    @Test(arguments: ["1e19", "100000.5", "2000", "-40", "0"])
    func `absurd branded serving sizes count as no serving`(size: String) throws {
        // 2000 KG is 2 000 000 g after conversion.
        let unit = size == "2000" ? "KG" : "GRM"
        let json = #"""
        {"totalHits": 1, "foods": [{"fdcId": 9100001, "description": "BAD SERVING", "dataType": "Branded",
         "servingSizeUnit": "\#(unit)", "servingSize": \#(size), "householdServingFullText": "1 bar",
         "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 400}]}]}
        """#
        let response = try #require(FDCSearchResponse.parse(Data(json.utf8)))
        let food = try #require(response.foods.compactMap(FDCFoodMapper.map).first)
        #expect(food.serving == nil)
        #expect(food.nutrients.kcal == 400)
    }

    @Test func `the largest usable branded serving is kept`() throws {
        let json = #"""
        {"totalHits": 1, "foods": [{"fdcId": 9100002, "description": "BULK", "dataType": "Branded",
         "servingSizeUnit": "KG", "servingSize": 100,
         "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 400}]}]}
        """#
        let response = try #require(FDCSearchResponse.parse(Data(json.utf8)))
        let food = try #require(response.foods.compactMap(FDCFoodMapper.map).first)
        #expect(food.serving?.amount == 100_000)
    }

    @Test func `foods without an fdcId and non-object entries are dropped`() throws {
        let response = try #require(FDCSearchResponse.parse(Fixture.data("search_edge_cases", in: "USDA")))
        #expect(response.foods.count == 7)
        #expect(try drafts("search_edge_cases").count == 5)
    }

    @Test func `empty result`() throws {
        #expect(try drafts("search_empty").isEmpty)
    }

    @Test(arguments: [
        ("KCAL", 100.0, 100.0), ("kcal", 100.0, 100.0), ("kJ", 418.4, 100.0), ("KJ", 418.4, 100.0),
    ])
    func `energy units`(unit: String, value: Double, kcal: Double) {
        #expect(isClose(FDCFoodMapper.kcal(value, unitName: unit, defaultUnit: "kcal"), kcal))
    }

    @Test func `mass units`() {
        #expect(FDCFoodMapper.grams(2, unitName: "G") == 2)
        #expect(isClose(FDCFoodMapper.grams(250, unitName: "MG"), 0.25))
        #expect(isClose(FDCFoodMapper.grams(5000, unitName: "UG"), 0.005, tolerance: 1e-9))
        #expect(FDCFoodMapper.grams(5, unitName: nil, defaultUnit: "mg") == 0.005)
        #expect(FDCFoodMapper.grams(5, unitName: "IU") == nil)
        #expect(FDCFoodMapper.kcal(5, unitName: "G", defaultUnit: "kcal") == nil)
    }

    @Test func `fdcFood survives an encode-decode round trip`() throws {
        let response = try #require(FDCSearchResponse.parse(Fixture.data("search_branded", in: "USDA")))
        let food = try #require(response.foods.first)
        let decoded = try JSONDecoder().decode(FDCFood.self, from: JSONEncoder().encode(food))
        #expect(decoded == food)
    }
}
