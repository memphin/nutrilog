import Foundation
import Testing
@testable import Core

struct EstimatedFoodTests {
    @Test func `totals become per-100 values and scale with the amount`() throws {
        var item = try #require(EstimatedFood(name: " Rice ", grams: 200, totalKcal: 260, totalProteinG: 5, totalCarbsG: 56, totalFatG: 0.6))
        #expect(item.name == "Rice")
        #expect(item.per100.kcal == 130)
        #expect(item.nutrients.kcal == 260)
        item.grams = 100
        #expect(item.nutrients.kcal == 130)
        #expect(item.nutrients.carbsG == 28)
    }

    @Test func `unusable items are nil and negatives count as zero`() {
        #expect(EstimatedFood(name: "", grams: 100, totalKcal: 1, totalProteinG: 0, totalCarbsG: 0, totalFatG: 0) == nil)
        #expect(EstimatedFood(name: "Air", grams: 0, totalKcal: 1, totalProteinG: 0, totalCarbsG: 0, totalFatG: 0) == nil)
        #expect(EstimatedFood(name: "X", grams: 10, totalKcal: .nan, totalProteinG: 0, totalCarbsG: 0, totalFatG: 0) == nil)
        #expect(EstimatedFood(name: "Water", grams: 250, totalKcal: -3, totalProteinG: 0, totalCarbsG: 0, totalFatG: 0)?.per100.kcal == 0)
    }
}

struct MealDescriptionTests {
    @Test func `splits foods and reads counts and amounts`() {
        let parts = MealDescription.parts("2 eggs, 150 g rice and a banana with 2dl of milk")
        #expect(parts == [
            .init(food: "eggs", count: 2),
            .init(food: "rice", grams: 150),
            .init(food: "banana", count: 1),
            .init(food: "milk", grams: 200),
        ])
    }

    @Test func `decimal comma, kilograms and a bare food`() {
        #expect(MealDescription.parts("0,5 kg chicken breast; Toast") == [
            .init(food: "chicken breast", grams: 500),
            .init(food: "toast"),
        ])
    }

    @Test func `empty and amount-only text gives nothing`() {
        #expect(MealDescription.parts("  , 200 g ,").isEmpty)
    }
}
