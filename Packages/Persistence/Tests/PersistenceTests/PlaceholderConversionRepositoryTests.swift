import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// `FoodRepository.saveConvertedPlaceholder`: setting the real serving weight of a per-serving placeholder keeps what
/// was already logged, planned or saved with it at "1 serving".
struct PlaceholderConversionRepositoryTests {
    /// Values of one serving (S).
    private let perServing = Nutrients(kcal: 150, proteinG: 3, carbsG: 20, fatG: 6)

    /// A per-serving placeholder: S stored as per 100, with a 100 g stand-in default serving.
    private func makePlaceholder(_ f: Fixture) throws -> FoodDetail {
        let standIn = Serving(label: "1 bar", grams: 100)
        var food = Food(name: "Bar", source: .off, sourceID: "123", per100: perServing)
        food.perServingOnly = true
        food.defaultServingID = standIn.id
        return try f.foods.save(FoodDetail(food: food, servings: [standIn]))
    }

    /// What FoodLookup's `convertingPerServingPlaceholder(servingWeight:)` produces.
    private func converted(_ detail: FoodDetail, weight: Double) -> FoodDetail {
        var result = detail
        result.food.per100 = Nutrients.per100(fromServing: detail.food.per100, servingGrams: weight)
        result.food.perServingOnly = false
        result.servings = detail.servings.map { serving in
            var updated = serving
            if serving.id == detail.food.defaultServingID {
                updated.grams = weight
            }
            return updated
        }
        return result
    }

    private func oneServing(_ detail: FoodDetail) -> Quantity {
        .servings(count: 1, serving: detail.servings[0].size)
    }

    private func expectOneServing(_ nutrients: Nutrients, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(nutrients.kcal - 150) < 1e-9, sourceLocation: sourceLocation)
        #expect(abs(nutrients.proteinG - 3) < 1e-9, sourceLocation: sourceLocation)
        #expect(abs(nutrients.carbsG - 20) < 1e-9, sourceLocation: sourceLocation)
        #expect(abs(nutrients.fatG - 6) < 1e-9, sourceLocation: sourceLocation)
    }

    private func queuedHealthWrites(_ f: Fixture) throws -> Int? {
        try f.db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM healthkit_outbox") }
    }

    @Test func `copying the day, confirming the plan and logging the meal give one serving after conversion`() throws {
        let f = try Fixture()
        let placeholder = try makePlaceholder(f)
        let plans = MealPlanRepository(f.db, clock: f.clock.appClock)
        let meals = MealTemplateRepository(f.db, clock: f.clock.appClock)
        let today = day("2026-11-09")
        let tomorrow = day("2026-11-10")

        let entry = try f.diary.log(
            food: placeholder.food, quantity: oneServing(placeholder), servingID: placeholder.servings[0].id,
            slotID: "breakfast", day: today,
        )
        expectOneServing(entry.nutrients)
        let planned = try plans.plan(food: placeholder.food, quantity: oneServing(placeholder), slotID: "lunch", day: tomorrow)
        let meal = try meals.create(name: "Snack", items: [.init(foodID: placeholder.food.id, grams: 100)])
        let entryBefore = try #require(try f.diary.entry(id: entry.id))
        let queuedBefore = try queuedHealthWrites(f)

        f.clock.advance(60)
        let stored = try f.foods.saveConvertedPlaceholder(converted(placeholder, weight: 30))
        #expect(stored.food.perServingOnly == false)
        #expect(stored.servings[0].grams == 30)

        // The old entry now holds the real weight, with its snapshot and Health state untouched.
        let entryAfter = try #require(try f.diary.entry(id: entry.id))
        #expect(abs(entryAfter.grams - 30) < 1e-9)
        #expect(entryAfter.nutrients == entryBefore.nutrients)
        #expect(entryAfter.servingLabel == entryBefore.servingLabel)
        #expect(entryAfter.revision == entryBefore.revision + 1)
        #expect(entryAfter.updatedAt == f.clock.now)
        #expect(try queuedHealthWrites(f) == queuedBefore)

        // Copy from yesterday.
        let copied = try f.diary.copy(from: today, to: tomorrow)
        let copiedID = try #require(copied.first)
        let copy = try #require(try f.diary.entry(id: copiedID))
        expectOneServing(copy.nutrients)
        #expect(abs(copy.grams - 30) < 1e-9)

        // Confirm the plan.
        let confirmed = try plans.confirm(plannedIDs: [planned.id])
        let eatenID = try #require(confirmed.first)
        let eaten = try #require(try f.diary.entry(id: eatenID))
        expectOneServing(eaten.nutrients)
        #expect(abs(eaten.grams - 30) < 1e-9)

        // Log the saved meal the way the app does: each item's saved amount at the food's current values.
        let mealDetail = try #require(try meals.detail(id: meal.id))
        let item = try #require(mealDetail.items.first)
        #expect(abs(item.item.grams - 30) < 1e-9)
        expectOneServing(item.nutrients)
        let logged = try meals.log(
            templateID: meal.id, items: [.init(food: item.food, quantity: .base(item.item.grams))], slotID: "dinner", day: today,
        )
        expectOneServing(logged[0].nutrients)
    }

    @Test func `the remembered base amount and soft-deleted rows are rescaled, serving counts are not`() throws {
        let f = try Fixture()
        let placeholder = try makePlaceholder(f)
        let d = day("2026-11-09")
        // Last quantity as a base amount (2 servings = 200 stand-in g).
        let deleted = try f.diary.log(food: placeholder.food, quantity: .base(200), slotID: "lunch", day: d)
        try f.diary.softDelete(entryIDs: [deleted.id])

        try f.foods.saveConvertedPlaceholder(converted(placeholder, weight: 40))
        let food = try #require(try f.foods.detail(id: placeholder.food.id)?.food)
        #expect(food.lastServingID == nil)
        #expect(try abs(#require(food.lastAmount) - 80) < 1e-9)
        let restoredBefore = try #require(try f.diary.entry(id: deleted.id))
        #expect(abs(restoredBefore.grams - 80) < 1e-9)

        // A serving count stays a count.
        let other = try makePlaceholderWithServingCount(f)
        try f.foods.saveConvertedPlaceholder(converted(other.detail, weight: 25))
        let otherFood = try #require(try f.foods.detail(id: other.detail.food.id)?.food)
        #expect(otherFood.lastServingID == other.detail.servings[0].id)
        #expect(otherFood.lastAmount == 3)
        #expect(try f.foods.detail(id: other.detail.food.id)?.suggestedQuantity.baseAmount == 75)
    }

    private func makePlaceholderWithServingCount(_ f: Fixture) throws -> (detail: FoodDetail, entry: DiaryEntry) {
        let standIn = Serving(label: "1 cup", grams: 100)
        var food = Food(name: "Drink", source: .off, sourceID: "456", per100: perServing)
        food.perServingOnly = true
        food.defaultServingID = standIn.id
        let detail = try f.foods.save(FoodDetail(food: food, servings: [standIn]))
        let entry = try f.diary.log(
            food: detail.food, quantity: .servings(count: 3, serving: detail.servings[0].size), servingID: standIn.id,
            slotID: "snacks", day: day("2026-11-09"),
        )
        return (detail, entry)
    }

    @Test func `rows are rescaled only once, and only for a food that is still a placeholder`() throws {
        let f = try Fixture()
        let placeholder = try makePlaceholder(f)
        let entry = try f.diary.log(
            food: placeholder.food, quantity: oneServing(placeholder), servingID: placeholder.servings[0].id,
            slotID: "breakfast", day: day("2026-11-09"),
        )
        let first = try f.foods.saveConvertedPlaceholder(converted(placeholder, weight: 30))
        // A second conversion from the stale placeholder (e.g. two prompts) is a plain save.
        try f.foods.saveConvertedPlaceholder(converted(placeholder, weight: 30))
        #expect(try abs(#require(try f.diary.entry(id: entry.id)).grams - 30) < 1e-9)
        // Editing the converted food's serving later doesn't touch logged amounts.
        var edited = first
        edited.servings[0].grams = 50
        try f.foods.saveConvertedPlaceholder(edited)
        #expect(try abs(#require(try f.diary.entry(id: entry.id)).grams - 30) < 1e-9)

        // An ordinary food's rows are never rescaled.
        let slice = Serving(label: "slice", grams: 25)
        let bread = try f.makeFood("Bread", servings: [slice])
        let breadEntry = try f.diary.log(food: bread, quantity: .base(50), slotID: "lunch", day: day("2026-11-09"))
        var breadDetail = try #require(try f.foods.detail(id: bread.id))
        breadDetail.food.defaultServingID = breadDetail.servings[0].id
        breadDetail.servings[0].grams = 40
        try f.foods.saveConvertedPlaceholder(breadDetail)
        #expect(try #require(try f.diary.entry(id: breadEntry.id)).grams == 50)
    }

    @Test func `amounts rescaled past the entry limit keep their snapshot, and a later edit scales it proportionally`() throws {
        let f = try Fixture()
        let placeholder = try makePlaceholder(f)
        let plans = MealPlanRepository(f.db, clock: f.clock.appClock)
        let d = day("2026-11-09")
        // 500 servings of the 100 g stand-in; the real serving weighs 1 kg, so the rescaled amount is 500,000 g.
        let entry = try f.diary.log(food: placeholder.food, quantity: .base(50000), slotID: "lunch", day: d)
        let planned = try plans.plan(food: placeholder.food, quantity: .base(50000), slotID: "dinner", day: d)
        let before = try #require(try f.diary.entry(id: entry.id))
        let plannedBefore = try #require(try plans.entry(id: planned.id))

        try f.foods.saveConvertedPlaceholder(converted(placeholder, weight: 1000))
        let after = try #require(try f.diary.entry(id: entry.id))
        #expect(after.grams == 500_000) // not capped: grams stay consistent with the snapshot
        #expect(after.nutrients == before.nutrients)
        #expect(try #require(try plans.entry(id: planned.id)).grams == 500_000)
        #expect(try #require(try f.foods.food(id: placeholder.food.id)).lastAmount == 500_000)

        // Editing to a normal amount: 50 servings (50,000 g, a tenth of the amount) → a tenth of the nutrients.
        try f.diary.updateQuantity(entryID: entry.id, quantity: .base(50000))
        let edited = try #require(try f.diary.entry(id: entry.id))
        #expect(edited.grams == 50000)
        #expect(abs(edited.nutrients.kcal - before.nutrients.kcal / 10) < 1e-6)
        #expect(abs(edited.nutrients.kcal - 50 * 150) < 1e-6) // 50 servings of the label values
        try plans.updateQuantity(plannedID: planned.id, quantity: .base(50000))
        let editedPlan = try #require(try plans.entry(id: planned.id))
        #expect(abs(editedPlan.nutrients.kcal - plannedBefore.nutrients.kcal / 10) < 1e-6)
    }

    @Test func `a converted food with out-of-range values is rejected and nothing changes`() throws {
        let f = try Fixture()
        let placeholder = try makePlaceholder(f)
        let entry = try f.diary.log(
            food: placeholder.food, quantity: oneServing(placeholder), servingID: placeholder.servings[0].id,
            slotID: "breakfast", day: day("2026-11-09"),
        )
        var bad = converted(placeholder, weight: 30)
        bad.servings[0].grams = 1_000_000
        #expect(throws: (any Error).self) { try f.foods.saveConvertedPlaceholder(bad) }
        #expect(try #require(try f.diary.entry(id: entry.id)).grams == 100)
        #expect(try #require(try f.foods.food(id: placeholder.food.id)).perServingOnly)
    }
}
