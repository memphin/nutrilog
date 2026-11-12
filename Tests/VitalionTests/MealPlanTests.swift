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

@MainActor
struct MealPlanFixTests {
    func environment() throws -> (AppEnvironment, Food) {
        let env = AppEnvironment.preview()
        let food = try #require(try env.foods?.save(FoodDetail(food: Food(
            name: "Oats",
            per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 7),
        ))).food)
        return (env, food)
    }

    @Test func `plan calories on a future day plans instead of logging`() throws {
        let (env, _) = try environment()
        let tomorrow = env.today.next
        let target = AddTarget(slotID: "lunch", day: tomorrow, planned: true)
        try QuickAddView.save(
            mode: target.quickAddMode, name: "Leftovers", nutrients: Nutrients(kcal: 500, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: target.slotID, environment: env,
        )
        #expect(try env.diary?.diary(for: tomorrow).entryCount == 0)
        let pending = try #require(try env.mealPlan?.pending(for: tomorrow))
        #expect(pending.count == 1)
        #expect(pending.first?.isQuickAdd == true)
        #expect(pending.first?.kcal == 500)

        let logTarget = AddTarget(slotID: "lunch", day: env.today)
        try QuickAddView.save(
            mode: logTarget.quickAddMode, name: "", nutrients: Nutrients(kcal: 200, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: logTarget.slotID, environment: env,
        )
        #expect(try env.diary?.diary(for: env.today).entryCount == 1)
    }

    @Test func `prep list starting tomorrow stays inside the loaded plan`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let window = MealPlanView.planWindow(today: today)
        for fromTomorrow in [false, true] {
            for days in 1 ... MealPlanView.horizon {
                let range = MealPlanView.prepRange(today: today, fromTomorrow: fromTomorrow, days: days)
                #expect(window.contains(range.lowerBound) && window.contains(range.upperBound))
                #expect(today.days(until: range.upperBound) - today.days(until: range.lowerBound) == days - 1)
            }
        }
        let lastDay = MealPlanView.prepRange(today: today, fromTomorrow: true, days: MealPlanView.horizon).upperBound
        #expect(lastDay == today.adding(days: MealPlanView.horizon))
        #expect(window.lowerBound == today)
    }

    @Test func `planned food in a switched off slot keeps its section`() async throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env, day: env.today.next)
        try env.mealPlan?.plan(food: food, quantity: .base(60), slotID: "snacks", day: model.day)
        let slots = try #require(try env.diary?.mealSlots(includeInactive: true)).map { slot in
            var copy = slot
            copy.isActive = slot.id != "snacks"
            return copy
        }
        try env.profiles?.saveMealSlots(slots)

        let diary = Task { await model.observeDiary() }
        let plan = Task { await model.observePlan() }
        defer {
            diary.cancel()
            plan.cancel()
        }
        #expect(await waitUntil { model.diary != nil && model.planned.count == 1 })
        #expect(model.diary?.sections.contains { $0.slot.id == "snacks" } == false)
        #expect(model.sections.map(\.id) == ["breakfast", "lunch", "dinner", "snacks"])
        #expect(model.planned(in: "snacks").count == 1)
        #expect(model.moveTargets(for: model.planned[0]).map(\.id) == ["breakfast", "lunch", "dinner", "snacks"])
    }

    @Test func `a logged entry can't move to a future day`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let entry = try #require(try env.diary?.log(food: food, quantity: .base(50), slotID: "lunch", day: model.today))
        model.move(entry, toSlot: "dinner", day: model.today.next)
        #expect(model.errorMessage != nil)
        #expect(try env.diary?.diary(for: model.today.next).entryCount == 0)
        #expect(try env.diary?.diary(for: model.today).entryCount == 1)

        model.errorMessage = nil
        model.move(entry, toSlot: "dinner", day: model.today.previous)
        #expect(model.errorMessage == nil)
        #expect(try env.diary?.diary(for: model.today.previous).entryCount == 1)
    }
}

/// Prep-list ticks (`PrepTickStore`): kept across launches per food and date range, hidden when that food's plan
/// changes, dropped once the range has started before today.
@MainActor
struct PrepTickTests {
    @Test func `prep list ticks survive a relaunch and follow the plan`() throws {
        let suite = "PrepTickTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let env = AppEnvironment.preview()
        let plan = try #require(env.mealPlan)
        let oats = try #require(try env.foods?.save(FoodDetail(food: Food(
            name: "Oats", per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 7),
        ))).food)
        let rice = try #require(try env.foods?.save(FoodDetail(food: Food(
            name: "Rice", per100: Nutrients(kcal: 130, proteinG: 3, carbsG: 28, fatG: 0.3),
        ))).food)
        let today = env.today
        for day in [today.next, today.adding(days: 2)] {
            try plan.plan(food: oats, quantity: .base(60), slotID: "breakfast", day: day)
            try plan.plan(food: rice, quantity: .base(150), slotID: "lunch", day: day)
        }
        let week = MealPlanView.prepRange(today: today, fromTomorrow: false, days: 7)
        func items(_ range: ClosedRange<LocalDay>) throws -> [String: PrepItem] {
            let list = try MealPlanRepository.prepList(plan.pending(in: range))
            return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        }

        let store = PrepTickStore(defaults: defaults)
        var list = try items(week)
        let oatsItem = try #require(list["Oats"]), riceItem = try #require(list["Rice"])
        store.toggle(oatsItem, in: week)
        store.toggle(riceItem, in: week)
        store.toggle(riceItem, in: week) // unticked again
        #expect(store.isTicked(oatsItem, in: week))
        #expect(!store.isTicked(riceItem, in: week))

        // A relaunch reads them back.
        var relaunched = PrepTickStore(defaults: defaults)
        #expect(relaunched.isTicked(oatsItem, in: week))
        #expect(!relaunched.isTicked(riceItem, in: week))

        // Another date range doesn't show them; switching back does.
        let shorter = MealPlanView.prepRange(today: today, fromTomorrow: false, days: 2)
        let shorterOats = try #require(try items(shorter)["Oats"])
        #expect(!relaunched.isTicked(shorterOats, in: shorter))
        #expect(relaunched.isTicked(oatsItem, in: week))

        // Another portion of oats is planned: the tick no longer matches what was prepped.
        try plan.plan(food: oats, quantity: .base(60), slotID: "breakfast", day: today.adding(days: 3))
        list = try items(week)
        let moreOats = try #require(list["Oats"])
        #expect(moreOats.portions == 3)
        #expect(!relaunched.isTicked(moreOats, in: week))

        // A tick of a list that started before today is dropped.
        relaunched.toggle(moreOats, in: week)
        relaunched.prune(before: today)
        #expect(relaunched.ticks.count == 1)
        relaunched.prune(before: today.next)
        #expect(relaunched.ticks.isEmpty)
        relaunched = PrepTickStore(defaults: defaults)
        #expect(relaunched.ticks.isEmpty)
    }
}
