import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

@MainActor
struct MealPlanTests {
    func environment() throws -> (AppEnvironment, Food) {
        let env = AppEnvironment.preview()
        let food = try #require(try env.foods?.save(FoodDetail(food: Food(
            name: "Oats",
            per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 7),
        ))).food)
        return (env, food)
    }

    @Test func `copying into a future day plans instead of logging`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        try env.diary?.log(food: food, quantity: .base(60), slotID: "breakfast", day: model.today)
        model.goToNextDay()
        #expect(model.isFuture)
        model.copy(from: model.today, slotID: nil)
        #expect(try env.diary?.diary(for: model.day).entryCount == 0)
        #expect(try env.mealPlan?.pending(for: model.day).count == 1)
        #expect(model.undo.current?.message == "Planned 1 entry")
        model.undo.performUndo()
        #expect(try env.mealPlan?.pending(for: model.day).isEmpty == true)
    }

    @Test func `confirming logs the plan and undo puts it back`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let plan = try #require(env.mealPlan)
        let planned = try plan.plan(food: food, quantity: .base(80), slotID: "breakfast", day: model.day)
        let ids = try #require(model.confirm([planned]))
        #expect(ids.count == 1)
        #expect(try env.diary?.diary(for: model.day).totals.kcal == 304)
        #expect(try plan.pending(for: model.day).isEmpty)
        #expect(model.undo.current?.message == "Logged Oats")
        model.undo.performUndo()
        #expect(try env.diary?.diary(for: model.day).entryCount == 0)
        #expect(try plan.pending(for: model.day).map(\.id) == [planned.id])
    }

    @Test func `repeat a meal on the next days`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        try env.mealPlan?.plan(food: food, quantity: .base(60), slotID: "lunch", day: model.day)
        model.repeatOnNextDays(slotID: "lunch", days: 4)
        let pending = try #require(try env.mealPlan?.pending(in: model.day.next ... model.day.adding(days: 6)))
        #expect(pending.map(\.day) == (1 ... 4).map { model.day.adding(days: $0) })
        model.repeatOnNextDays(slotID: "dinner", days: 2)
        #expect(model.errorMessage?.hasPrefix("Nothing to plan") == true)
    }

    @Test func `removing a planned entry offers undo`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let planned = try #require(try env.mealPlan?.plan(food: food, quantity: .base(60), slotID: "lunch", day: model.day))
        model.deletePlanned([planned])
        #expect(try env.mealPlan?.pending(for: model.day).isEmpty == true)
        model.undo.performUndo()
        #expect(try env.mealPlan?.pending(for: model.day).count == 1)
    }
}
