import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct MealTemplateRepositoryTests {
    let d = day("2026-11-09")

    private func breakfast(_ f: Fixture) throws -> (oats: Food, milk: Food) {
        let oats = try f.makeFood("Oats", kcal: 380)
        let milk = try f.makeFood("Milk", kcal: 60)
        try f.diary.log(food: oats, quantity: .base(60), slotID: "breakfast", day: d)
        try f.diary.log(food: milk, quantity: .base(250), slotID: "breakfast", day: d)
        try f.diary.logQuickAdd(
            name: "Coffee",
            nutrients: Nutrients(kcal: 20, proteinG: 0, carbsG: 2, fatG: 1),
            slotID: "breakfast",
            day: d,
        )
        return (oats, milk)
    }

    @Test func `save as meal takes the food entries of the slot`() throws {
        let f = try Fixture()
        let foods = try breakfast(f)
        try f.diary.log(food: foods.oats, quantity: .base(999), slotID: "lunch", day: d)
        let meal = try f.meals.createFromDiary(day: d, slotID: "breakfast", name: " Usual breakfast ")
        #expect(meal.template.name == "Usual breakfast")
        #expect(meal.template.mealSlotHint == "breakfast")
        #expect(meal.items.map(\.food.name) == ["Oats", "Milk"]) // the quick-add has no food
        #expect(meal.items.map(\.item.grams) == [60, 250])
        #expect(meal.totals.kcal == 0.6 * 380 + 2.5 * 60)
        #expect(!meal.hasDeletedFoods)

        #expect(throws: Persistence.PersistenceError.self) { try f.meals.createFromDiary(day: d, slotID: "dinner", name: "Empty") }
        #expect(throws: Persistence.PersistenceError.self) { try f.meals.createFromDiary(day: d, slotID: "breakfast", name: " ") }
        #expect(try f.meals.templates().count == 1) // failed creates left nothing behind
    }

    @Test func `logging a meal adds every item in one go and counts the use`() throws {
        let f = try Fixture()
        _ = try breakfast(f)
        let meal = try f.meals.createFromDiary(day: d, slotID: "breakfast", name: "Usual")
        f.clock.advance(86400)
        // Editable before confirming: more milk.
        let items = meal.items.map { item in
            DiaryRepository.LogItem(food: item.food, quantity: .base(item.food.name == "Milk" ? 300 : item.item.grams))
        }
        let entries = try f.meals.log(templateID: meal.id, items: items, slotID: "snacks", day: d.next)
        #expect(entries.map(\.grams) == [60, 300])
        let diary = try f.diary.diary(for: d.next)
        #expect(diary.entryCount == 2)
        #expect(diary.sections.first { $0.slot.id == "snacks" }?.entries.map(\.displayName) == ["Oats", "Milk"])
        let stored = try #require(try f.meals.detail(id: meal.id))
        #expect(stored.template.useCount == 1)
        #expect(stored.template.lastUsedAt == f.clock.now)
        #expect(stored.items.map(\.item.grams) == [60, 250]) // the template itself is unchanged
        #expect(try f.foods.food(id: meal.items[0].food.id)?.useCount == 2)
        // Every entry is queued for Apple Health like any other.
        #expect(try f.healthLinks.pending().count(where: { $0.ownerTable == .diaryEntry }) == 5)
    }

    @Test func `a failing item rolls the whole meal back`() throws {
        let f = try Fixture()
        _ = try breakfast(f)
        let meal = try f.meals.createFromDiary(day: d, slotID: "breakfast", name: "Usual")
        let ghost = Food(name: "Ghost", per100: .zero)
        let items = [
            DiaryRepository.LogItem(food: meal.items[0].food, quantity: .base(60)),
            DiaryRepository.LogItem(food: ghost, quantity: .base(10)),
        ]
        #expect(throws: Persistence.PersistenceError.self) {
            try f.meals.log(templateID: meal.id, items: items, slotID: "lunch", day: d.next)
        }
        #expect(try f.diary.diary(for: d.next).entryCount == 0)
        #expect(try f.meals.detail(id: meal.id)?.template.useCount == 0)
        #expect(throws: Persistence.PersistenceError.self) { try f.meals.log(templateID: meal.id, items: [], slotID: "lunch", day: d.next) }
    }

    @Test func `items of deleted foods are flagged and the meal is still loggable`() throws {
        let f = try Fixture()
        let foods = try breakfast(f)
        let meal = try f.meals.createFromDiary(day: d, slotID: "breakfast", name: "Usual")
        try f.foods.softDelete(id: foods.milk.id)
        let stored = try #require(try f.meals.detail(id: meal.id))
        #expect(stored.hasDeletedFoods)
        #expect(stored.items.map(\.isFoodDeleted) == [false, true])
        #expect(stored.totals.kcal == meal.totals.kcal)
        let uses = try #require(try f.foods.food(id: foods.milk.id)).useCount

        let entries = try f.meals.log(
            templateID: meal.id, items: stored.items.map { DiaryRepository.LogItem(food: $0.food, quantity: .base($0.item.grams)) },
            slotID: "breakfast", day: d.next,
        )
        #expect(entries.count == 2)
        #expect(entries[1].displayName == "Milk")
        #expect(entries[1].kcal == 150)
        let deleted = try #require(try f.foods.food(id: foods.milk.id))
        #expect(deleted.deletedAt != nil) // logging doesn't bring the food back
        #expect(deleted.useCount == uses)
    }

    @Test func `meals are ranked by use count and recency`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice")
        let item = [MealTemplateRepository.NewItem(foodID: rice.id, grams: 100)]
        let often = try f.meals.create(name: "Often", items: item)
        let lately = try f.meals.create(name: "Lately", items: item)
        let never = try f.meals.create(name: "Aardvark never used", items: item)
        let log = [DiaryRepository.LogItem(food: rice, quantity: .base(100))]
        for _ in 0 ..< 5 {
            try f.meals.log(templateID: often.id, items: log, slotID: "lunch", day: d)
        }
        f.clock.advance(20 * 86400)
        try f.meals.log(templateID: lately.id, items: log, slotID: "lunch", day: d)
        // 5 uses 20 days ago (score ≈ 3.1) beat 1 use today.
        #expect(try f.meals.templates().map(\.template.name) == ["Often", "Lately", "Aardvark never used"])
        f.clock.advance(90 * 86400)
        try f.meals.log(templateID: lately.id, items: log, slotID: "lunch", day: d)
        // 110 days later the old favourite has faded.
        #expect(try f.meals.templates().map(\.template.name) == ["Lately", "Often", "Aardvark never used"])
        _ = never
    }

    @Test func `rename, edit items, delete and restore`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice")
        let beans = try f.makeFood("Beans")
        let meal = try f.meals.create(name: "Bowl", items: [.init(foodID: rice.id, grams: 100), .init(foodID: beans.id, grams: 50)])
        try f.meals.rename(id: meal.id, to: "Rice bowl")
        try f.meals.setItems(id: meal.id, items: [.init(foodID: beans.id, grams: 80)])
        let edited = try #require(try f.meals.detail(id: meal.id))
        #expect(edited.template.name == "Rice bowl")
        #expect(edited.items.map(\.food.name) == ["Beans"])
        #expect(edited.items[0].item.grams == 80)
        #expect(throws: Persistence.PersistenceError.self) { try f.meals.rename(id: meal.id, to: "") }
        #expect(throws: Persistence.PersistenceError.self) { try f.meals.setItems(id: meal.id, items: []) }
        #expect(throws: Persistence.PersistenceError.self) { try f.meals.create(name: "X", items: [.init(foodID: "missing", grams: 10)]) }

        try f.meals.softDelete(id: meal.id)
        #expect(try f.meals.templates().isEmpty)
        try f.meals.restore(id: meal.id)
        #expect(try f.meals.templates().map(\.id) == [meal.id])
    }
}
