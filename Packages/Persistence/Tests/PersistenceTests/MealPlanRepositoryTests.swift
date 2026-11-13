import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct MealPlanRepositoryTests {
    private func plans(_ f: Fixture) -> MealPlanRepository {
        MealPlanRepository(f.db, clock: f.clock.appClock)
    }

    @Test func `a plan is not eaten: no diary entry, no totals, no Health write`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let d = day("2026-11-12")
        let planned = try plans(f).plan(food: rice, quantity: .base(200), slotID: "lunch", day: d)
        #expect(planned.kcal == 260)
        #expect(try plans(f).pending(for: d).map(\.id) == [planned.id])
        #expect(try f.diary.diary(for: d).entryCount == 0)
        #expect(try f.diary.daySummaries(in: d ... d).isEmpty)
        let queued = try f.db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM healthkit_outbox") }
        #expect(queued == 0)
        // Planning is not using the food yet.
        #expect(try f.foods.detail(id: rice.id)?.food.useCount == 0)
    }

    @Test func `confirming logs a diary entry from current values and hides the plan`() throws {
        let f = try Fixture()
        let slice = Serving(label: "slice", grams: 25)
        let bread = try f.makeFood("Bread", kcal: 240, servings: [slice])
        let detail = try #require(try f.foods.detail(id: bread.id))
        let d = day("2026-11-12")
        let planned = try plans(f).plan(
            food: bread, quantity: .servings(count: 2, serving: detail.servings[0].size), slotID: "breakfast", day: d,
        )
        // The food changes between planning and eating: the diary gets what the food says now.
        var changed = detail
        changed.food.per100 = Nutrients(kcal: 200, proteinG: 8, carbsG: 40, fatG: 2)
        try f.foods.save(changed)

        f.clock.advance(3600)
        let ids = try plans(f).confirm(plannedIDs: [planned.id])
        let entryID = try #require(ids.first)
        let entry = try #require(try f.diary.entry(id: entryID))
        #expect(entry.day == d)
        #expect(entry.mealSlotID == "breakfast")
        #expect(entry.grams == 50)
        #expect(entry.kcal == 100)
        #expect(entry.servingLabel == "2 × slice")
        #expect(entry.loggedAt == f.clock.now)
        #expect(try plans(f).pending(for: d).isEmpty)
        #expect(try f.foods.detail(id: bread.id)?.food.useCount == 1)
        let queued = try f.db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM healthkit_outbox") }
        #expect(queued == 1)

        // Confirming twice logs nothing more.
        #expect(try plans(f).confirm(plannedIDs: [planned.id]).isEmpty)
    }

    @Test func `deleting the eaten entry makes the plan pending again`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Chicken", kcal: 165)
        let d = day("2026-11-12")
        let planned = try plans(f).plan(food: food, quantity: .base(150), slotID: "dinner", day: d)
        let ids = try plans(f).confirm(plannedIDs: [planned.id])
        try f.diary.softDelete(entryIDs: ids) // the undo of "Eaten"
        #expect(try plans(f).pending(for: d).map(\.id) == [planned.id])
        let again = try plans(f).confirm(plannedIDs: [planned.id])
        #expect(again.count == 1)
        #expect(again != ids)
    }

    @Test func `quick add plans keep their estimate when confirmed`() throws {
        let f = try Fixture()
        let d = day("2026-11-13")
        let planned = try plans(f).planQuickAdd(
            name: " Pizza ", nutrients: Nutrients(kcal: 800, proteinG: 30, carbsG: 90, fatG: 30), slotID: "dinner", day: d,
        )
        #expect(planned.displayName == "Pizza")
        let entryID = try #require(try plans(f).confirm(plannedIDs: [planned.id]).first)
        let entry = try #require(try f.diary.entry(id: entryID))
        #expect(entry.isQuickAdd)
        #expect(entry.kcal == 800)
        #expect(entry.displayName == "Pizza")
    }

    @Test func `edit, move, delete and restore`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Oats", kcal: 380)
        let d = day("2026-11-12")
        let repo = plans(f)
        let planned = try repo.plan(food: food, quantity: .base(50), slotID: "breakfast", day: d)
        try repo.updateQuantity(plannedID: planned.id, quantity: .base(100))
        #expect(try repo.entry(id: planned.id)?.kcal == 380)
        #expect(throws: Persistence.PersistenceError.self) { try repo.updateQuantity(plannedID: planned.id, quantity: .base(0)) }

        try repo.move(plannedID: planned.id, toSlot: "snacks", day: d.next)
        #expect(try repo.pending(for: d).isEmpty)
        #expect(try repo.pending(for: d.next).first?.mealSlotID == "snacks")

        try repo.softDelete(plannedIDs: [planned.id])
        #expect(try repo.pending(in: d ... d.adding(days: 6)).isEmpty)
        try repo.restore(plannedIDs: [planned.id])
        #expect(try repo.pending(in: d ... d.adding(days: 6)).count == 1)
    }

    @Test func `pending is ordered by day, slot order and position`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Egg", kcal: 140)
        let d = day("2026-11-12")
        let repo = plans(f)
        let dinner = try repo.plan(food: food, quantity: .base(50), slotID: "dinner", day: d)
        let breakfast = try repo.plan(food: food, quantity: .base(50), slotID: "breakfast", day: d)
        let breakfast2 = try repo.plan(food: food, quantity: .base(60), slotID: "breakfast", day: d)
        let tomorrow = try repo.plan(food: food, quantity: .base(50), slotID: "breakfast", day: d.next)
        #expect(try repo.pending(in: d ... d.next).map(\.id) == [breakfast.id, breakfast2.id, dinner.id, tomorrow.id])
    }

    @Test func `copy a day into the plan of another day`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let chicken = try f.makeFood("Chicken", kcal: 165)
        let source = day("2026-11-11")
        try f.diary.log(food: rice, quantity: .base(200), slotID: "lunch", day: source)
        try f.diary.log(food: chicken, quantity: .base(150), slotID: "dinner", day: source)
        let repo = plans(f)
        let target = day("2026-11-12")

        let lunchOnly = try repo.copyToPlan(from: source, slotID: "lunch", to: target)
        #expect(lunchOnly.count == 1)
        let whole = try repo.copyToPlan(from: source, to: target)
        #expect(whole.count == 2)
        #expect(try repo.pending(for: target).count == 3)
        // Nothing was logged.
        #expect(try f.diary.diary(for: target).entryCount == 0)

        // A planned day copies its pending plan, into the same slots.
        let fromPlan = try repo.copyToPlan(from: target, slotID: "dinner", to: day("2026-11-15"))
        #expect(fromPlan.count == 1)
        #expect(try repo.pending(for: day("2026-11-15")).first?.mealSlotID == "dinner")
    }

    @Test func `prep list sums each food over the days`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let chicken = try f.makeFood("chicken breast", kcal: 165)
        let repo = plans(f)
        let d = day("2026-11-12")
        for offset in 0 ..< 3 {
            try repo.plan(food: rice, quantity: .base(200), slotID: "lunch", day: d.adding(days: offset))
            try repo.plan(food: chicken, quantity: .base(150), slotID: "lunch", day: d.adding(days: offset))
        }
        try repo.plan(food: rice, quantity: .base(100), slotID: "dinner", day: d)
        let bar = Nutrients(kcal: 200, proteinG: 20, carbsG: 20, fatG: 5)
        try repo.planQuickAdd(name: "Protein bar", nutrients: bar, slotID: "snacks", day: d)

        let list = try MealPlanRepository.prepList(repo.pending(in: d ... d.adding(days: 6)))
        #expect(list.map(\.name) == ["chicken breast", "Protein bar", "Rice"])
        let riceItem = try #require(list.first { $0.foodID == rice.id })
        #expect(riceItem.totalGrams == 700)
        #expect(riceItem.portions == 4)
        #expect(riceItem.days == [d, d.next, d.adding(days: 2)])
        #expect(riceItem.nutrients.kcal == 910)
        #expect(list.first { $0.isQuickAdd }?.totalGrams == 0)
    }

    @Test func `plans are exported and merging foods follows them`() throws {
        let f = try Fixture()
        let a = try f.makeFood("Yogurt")
        let b = try f.makeFood("Yoghurt")
        let planned = try plans(f).plan(food: b, quantity: .base(150), slotID: "breakfast", day: day("2026-11-12"))
        _ = try f.foods.merge(keep: a.id, remove: [b.id])
        #expect(try plans(f).entry(id: planned.id)?.foodID == a.id)

        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: Any])
        #expect((tables["planned_entry"] as? [Any])?.count == 1)
    }
}
