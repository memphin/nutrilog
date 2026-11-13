import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

@MainActor
struct MealEditorTests {
    let clock = ManualClock()
    let env: AppEnvironment

    init() {
        env = AppEnvironment.preview(clock: clock.appClock)
    }

    @Test func `save as meal, then log it with a changed amount`() throws {
        let foods = try #require(env.foods), diary = try #require(env.diary), meals = try #require(env.meals)
        let oats = try foods.save(FoodDetail(food: Food(name: "Oats", per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 6))))
            .food
        let milk = try foods.save(FoodDetail(
            food: Food(name: "Milk", per100: Nutrients(kcal: 60, proteinG: 3, carbsG: 5, fatG: 3), isLiquid: true),
        )).food
        try diary.log(food: oats, quantity: .base(60), slotID: "breakfast", day: env.today)
        try diary.log(food: milk, quantity: .base(250), slotID: "breakfast", day: env.today)

        let model = DiaryModel(environment: env)
        #expect(model.saveAsMeal(slotID: "breakfast", name: "Porridge"))
        #expect(model.undo.current?.message.contains("Porridge") == true)
        #expect(!model.saveAsMeal(slotID: "dinner", name: "Nothing"))
        #expect(model.errorMessage == "This meal has no foods to save.")

        let meal = try #require(try meals.templates().first)
        var draft = MealLogDraft(meal)
        #expect(draft.lines.map(\.amountText) == ["60", "250"])
        #expect(draft.totals.kcal == 228 + 150)
        draft.lines[1].amountText = "300"
        #expect(draft.totals.kcal == 228 + 180)
        draft.lines[0].amountText = ""
        #expect(draft.logItems == nil) // an included line without an amount blocks logging
        draft.lines[0].isIncluded = false
        let items = try #require(draft.logItems)
        #expect(items.count == 1)
        try meals.log(templateID: meal.id, items: items, slotID: "snacks", day: env.today.next)
        #expect(try diary.totals(for: env.today.next).kcal == 180)
        draft.lines[1].isIncluded = false
        #expect(draft.logItems == nil)

        // Undo removes the saved meal.
        model.undo.current?.undo()
        #expect(try meals.templates().isEmpty)
    }

    @Test func `meal editor: create a meal from foods`() throws {
        let foods = try #require(env.foods), meals = try #require(env.meals)
        let rice = try foods.save(FoodDetail(food: Food(name: "Rice", per100: Nutrients(kcal: 360, proteinG: 7, carbsG: 79, fatG: 1)))).food
        let milk = try foods.save(FoodDetail(
            food: Food(name: "Milk", per100: Nutrients(kcal: 60, proteinG: 3, carbsG: 5, fatG: 3), isLiquid: true),
        )).food
        let model = MealEditorModel()
        #expect(model.isNew)
        #expect(model.validationErrors == ["Give the meal a name.", "Add at least one food."])
        #expect(model.totals == .zero)

        model.name = " Rice pudding "
        model.add(rice)
        model.add(milk)
        #expect(model.rows.map(\.amountText) == ["100", "100"])
        #expect(model.rows.map(\.food.baseUnit) == [.grams, .milliliters])
        model.rows[0].amountText = "50"
        model.rows[1].amountText = "200,5"
        #expect(model.validationErrors.isEmpty)
        #expect(model.rows[1].amount == 200.5) // "," or "." as the decimal separator
        #expect(abs(model.totals.kcal - (180 + 120.3)) < 0.001)
        #expect(abs(model.totals.proteinG - (3.5 + 6.015)) < 0.001)

        model.rows[1].amountText = "abc"
        #expect(model.validationErrors == ["Every food needs an amount greater than zero."])
        #expect(model.items == nil)
        #expect(model.totals.kcal == 180) // an invalid amount counts as nothing
        #expect(throws: PersistenceError.self) { try model.save(to: meals) }
        #expect(try meals.templates().isEmpty)
        model.rows[1].amountText = "0"
        #expect(model.validationErrors.count == 1)
        // Too large: its own message (zero/empty keeps the one above, and wins when both occur).
        model.rows[1].amountText = "100001"
        #expect(model.validationErrors == ["An amount can't be more than \(EntryLimits.maxAmount.formatted(.number.precision(.fractionLength(0))))."])
        #expect(model.validationErrors == [MealEditorModel.tooLargeAmountMessage])
        model.rows[1].amountText = "1e30"
        #expect(model.validationErrors == [MealEditorModel.tooLargeAmountMessage])
        #expect(throws: PersistenceError.validation(MealEditorModel.tooLargeAmountMessage)) { try model.save(to: meals) }
        model.rows[0].amountText = ""
        #expect(model.validationErrors == ["Every food needs an amount greater than zero."])
        model.rows[0].amountText = "50"
        model.rows[1].amountText = "200"
        model.move(fromOffsets: [1], toOffset: 0)

        let saved = try model.save(to: meals)
        #expect(!model.isNew)
        #expect(saved.template.name == "Rice pudding")
        #expect(saved.items.map(\.food.id) == [milk.id, rice.id])
        #expect(saved.items.map(\.item.grams) == [200, 50])
        #expect(saved.totals.kcal == 300)
        #expect(try meals.templates().map(\.id) == [saved.id])
        // Saving again updates the same meal.
        model.name = "Pudding"
        #expect(try model.save(to: meals).id == saved.id)
        #expect(try meals.templates().map(\.template.name) == ["Pudding"])
    }

    @Test func `meal editor: a food is added with the amount chosen for it, keeping its serving`() throws {
        let foods = try #require(env.foods), meals = try #require(env.meals)
        let bread = try foods.save(FoodDetail(
            food: Food(name: "Bread", per100: Nutrients(kcal: 250, proteinG: 9, carbsG: 48, fatG: 3)),
            servings: [Serving(label: "slice", grams: 30)],
        ))
        let slice = try #require(bread.servings.first)
        let model = MealEditorModel()
        model.name = "Toast"
        model.add(bread.food, quantity: .servings(count: 2, serving: slice.size), servingID: slice.id)
        model.add(bread.food, quantity: .base(45))
        #expect(model.rows.map(\.amountText) == ["60", "45"])
        #expect(abs(model.totals.kcal - 262.5) < 0.001)

        let saved = try model.save(to: meals)
        #expect(saved.items.map(\.item.grams) == [60, 45])
        #expect(saved.items.map(\.item.servingID) == [slice.id, nil])
    }

    @Test func `meal editor: change amounts, remove and add foods of an existing meal`() throws {
        let foods = try #require(env.foods), meals = try #require(env.meals)
        let oats = try foods.save(FoodDetail(
            food: Food(name: "Oats", per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 6)),
            servings: [Serving(label: "cup", grams: 80)],
        ))
        let milk = try foods.save(FoodDetail(
            food: Food(name: "Milk", per100: Nutrients(kcal: 60, proteinG: 3, carbsG: 5, fatG: 3), isLiquid: true),
        )).food
        let honey = try foods.save(FoodDetail(food: Food(name: "Honey", per100: Nutrients(kcal: 300, proteinG: 0, carbsG: 80, fatG: 0))))
            .food
        let cup = try #require(oats.servings.first)
        let meal = try meals.create(name: "Porridge", slotHint: "breakfast", items: [
            .init(foodID: oats.food.id, grams: 80, servingID: cup.id),
            .init(foodID: milk.id, grams: 250),
            .init(foodID: honey.id, grams: 10),
        ])

        let model = try MealEditorModel(meal: #require(try meals.detail(id: meal.id)))
        #expect(!model.isNew)
        #expect(model.name == "Porridge")
        #expect(model.rows.map(\.amountText) == ["80", "250", "10"])
        #expect(abs(model.totals.kcal - (304 + 150 + 30)) < 0.001)
        #expect(model.validationErrors.isEmpty)

        model.rows[1].amountText = "300"
        model.remove(atOffsets: [2])
        #expect(abs(model.totals.kcal - (304 + 180)) < 0.001)
        let saved = try model.save(to: meals)
        #expect(saved.id == meal.id)
        #expect(saved.template.name == "Porridge")
        #expect(saved.items.map(\.food.id) == [oats.food.id, milk.id])
        #expect(saved.items.map(\.item.grams) == [80, 300])
        #expect(saved.items[0].item.servingID == cup.id) // an untouched item keeps its serving
        #expect(try meals.templates().count == 1)

        // Rename only: the items are left alone.
        let renamed = try MealEditorModel(meal: #require(try meals.detail(id: meal.id)))
        renamed.name = "Big porridge"
        let itemIDs = saved.items.map(\.id)
        #expect(try renamed.save(to: meals).items.map(\.id) == itemIDs)
        #expect(try meals.detail(id: meal.id)?.template.name == "Big porridge")

        // A changed amount drops the serving; a removed-everything meal can't be saved.
        renamed.rows[0].amountText = "40"
        renamed.add(honey)
        let again = try renamed.save(to: meals)
        #expect(again.items.map(\.item.grams) == [40, 300, 100])
        #expect(again.items[0].item.servingID == nil)
        renamed.remove(atOffsets: [0, 1, 2])
        #expect(renamed.validationErrors == ["Add at least one food."])
        renamed.name = "  "
        #expect(renamed.validationErrors == ["Give the meal a name.", "Add at least one food."])
        #expect(throws: PersistenceError.self) { try renamed.save(to: meals) }
        #expect(try meals.detail(id: meal.id)?.items.count == 3)
    }

    @Test func `foods tab lists meals and deleting one can be undone`() throws {
        let foods = try #require(env.foods), meals = try #require(env.meals)
        let rice = try foods.save(FoodDetail(food: Food(name: "Rice", per100: Nutrients(kcal: 360, proteinG: 7, carbsG: 79, fatG: 1)))).food
        let meal = try meals.create(name: "Lunch box", items: [.init(foodID: rice.id, grams: 150)])
        let model = FoodsListModel(environment: env)
        model.reload()
        #expect(model.meals.map(\.id) == [meal.id])
        model.query = "rice"
        #expect(model.filteredMeals.count == 1) // a meal is found by its foods too
        model.query = "soup"
        #expect(model.filteredMeals.isEmpty)

        model.delete(meal)
        #expect(model.meals.isEmpty)
        #expect(model.undo.current?.message == "Deleted Lunch box")
        model.undo.current?.undo()
        #expect(model.meals.map(\.id) == [meal.id])
    }

    @Test func `a meal logged today is saved as a meal in one step`() throws {
        let foods = try #require(env.foods), diary = try #require(env.diary)
        let rice = try foods.save(FoodDetail(food: Food(name: "Rice", per100: Nutrients(kcal: 360, proteinG: 7, carbsG: 79, fatG: 1)))).food
        let slots = try diary.mealSlots()
        let breakfast = try #require(slots.first), lunch = try #require(slots.dropFirst().first)
        try diary.log(food: rice, quantity: .base(150), slotID: lunch.id, day: env.today)
        try diary.logQuickAdd(name: "Coffee", nutrients: Nutrients(kcal: 5, proteinG: 0, carbsG: 0, fatG: 0), slotID: breakfast.id, day: env.today)
        let model = FoodsListModel(environment: env)
        model.reload()
        #expect(model.todaySlots.first { $0.slot.id == lunch.id }?.foodCount == 1)
        #expect(model.todaySlots.first { $0.slot.id == breakfast.id }?.foodCount == 0) // a quick add can't be saved

        model.saveMeal(from: lunch, name: " ")
        #expect(model.errorMessage == nil)
        #expect(model.meals.map(\.template.name) == [lunch.name])
        #expect(model.meals.first?.items.map(\.item.grams) == [150])
    }
}
