import Core
import Foundation
import Testing
@testable import Persistence

struct DiaryRepositoryTests {
    @Test func `log snapshots nutrients and records use`() throws {
        let f = try Fixture()
        let slice = Serving(label: "slice", grams: 25)
        let bread = try f.makeFood("Bread", kcal: 240, protein: 8, carbs: 44, fat: 3, servings: [slice])
        let detail = try #require(try f.foods.detail(id: bread.id))
        let entry = try f.diary.log(
            food: bread, quantity: .servings(count: 2, serving: detail.servings[0].size),
            servingID: detail.servings[0].id, slotID: "breakfast", day: day("2026-11-09"),
        )
        #expect(entry.grams == 50)
        #expect(entry.kcal == 120)
        #expect(entry.servingLabel == "2 × slice")
        #expect(entry.displayName == "Bread")

        let used = try #require(try f.foods.detail(id: bread.id))
        #expect(used.food.useCount == 1)
        #expect(used.food.lastUsedAt == f.clock.now)
        #expect(used.suggestedQuantity == .servings(count: 2, serving: slice.size))

        try f.diary.log(food: bread, quantity: .base(80), slotID: "lunch", day: day("2026-11-09"))
        #expect(try f.foods.detail(id: bread.id)?.suggestedQuantity == .base(80))
    }

    @Test func `snapshot is not recalculated when food changes`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Cheese", kcal: 400)
        try f.diary.log(food: food, quantity: .base(50), slotID: "lunch", day: day("2026-11-09"))
        var detail = try #require(try f.foods.detail(id: food.id))
        detail.food.per100 = Nutrients(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1)
        try f.foods.save(detail)
        #expect(try f.diary.totals(for: day("2026-11-09")).kcal == 200)
    }

    @Test func `totals across slots and quick add`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Rice", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3)
        try f.diary.log(food: food, quantity: .base(200), slotID: "lunch", day: d)
        try f.diary.log(food: food, quantity: .base(100), slotID: "dinner", day: d)
        let quick = try f.diary.logQuickAdd(
            name: "  ",
            nutrients: Nutrients(kcal: 250, proteinG: 0, carbsG: 30, fatG: 10),
            slotID: "snacks",
            day: d,
        )
        #expect(quick.isQuickAdd)
        #expect(quick.foodID == nil)
        #expect(quick.displayName == "Quick add")

        let diary = try f.diary.diary(for: d)
        #expect(diary.sections.map(\.slot.id) == ["breakfast", "lunch", "dinner", "snacks"])
        #expect(diary.entryCount == 3)
        #expect(diary.totals.kcal == 640) // 260 + 130 + 250
        #expect(abs(diary.totals.proteinG - 8.1) < 1e-9)
        #expect(diary.sections[1].totals.kcal == 260)
        #expect(try f.diary.totals(for: d.next) == .zero)
    }

    @Test func `move reorder duplicate`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Egg")
        let a = try f.diary.log(food: food, quantity: .base(50), slotID: "breakfast", day: d)
        let b = try f.diary.log(food: food, quantity: .base(60), slotID: "breakfast", day: d)
        let c = try f.diary.log(food: food, quantity: .base(70), slotID: "breakfast", day: d)
        #expect([a, b, c].map(\.sortOrder) == [0, 1, 2])

        try f.diary.reorder(day: d, slotID: "breakfast", orderedIDs: [c.id, a.id, b.id, "unknown"])
        #expect(try f.diary.diary(for: d).sections[0].entries.map(\.id) == [c.id, a.id, b.id])

        try f.diary.move(entryID: a.id, toSlot: "lunch", day: d.next)
        try f.diary.move(entryID: a.id, toSlot: "lunch", day: d.next) // no-op
        let moved = try #require(try f.diary.entry(id: a.id))
        #expect(moved.day == d.next)
        #expect(moved.mealSlotID == "lunch")
        #expect(moved.revision == 3) // reorder + move
        #expect(try f.diary.diary(for: d).entryCount == 2)

        let copy = try f.diary.duplicate(entryID: b.id)
        #expect(copy.id != b.id)
        #expect(copy.kcal == b.kcal)
        #expect(copy.sortOrder == 3)
        #expect(throws: PersistenceError.notFound("x")) { try f.diary.move(entryID: "x", toSlot: "lunch", day: d) }
    }

    @Test func `update quantity scales existing snapshot`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Pasta", kcal: 350)
        let e = try f.diary.log(food: food, quantity: .base(100), slotID: "dinner", day: day("2026-11-09"))
        // Food changes afterwards — editing the amount must keep the original per-100 values.
        var detail = try #require(try f.foods.detail(id: food.id))
        detail.food.kcal100 = 999
        try f.foods.save(detail)
        try f.diary.updateQuantity(entryID: e.id, quantity: .servings(count: 1.5, serving: ServingSize(label: "plate", amount: 100)))
        let updated = try #require(try f.diary.entry(id: e.id))
        #expect(updated.grams == 150)
        #expect(updated.kcal == 525)
        #expect(updated.servingLabel == "1.5 × plate")
    }

    @Test func `zero or negative amounts are rejected`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Oats", kcal: 380)
        #expect(throws: PersistenceError.self) { try f.diary.log(food: food, quantity: .base(0), slotID: "breakfast", day: d) }
        let e = try f.diary.log(food: food, quantity: .base(50), slotID: "breakfast", day: d)
        #expect(throws: PersistenceError.self) { try f.diary.updateQuantity(entryID: e.id, quantity: .base(0)) }
        #expect(try f.diary.entry(id: e.id)?.grams == 50)
    }

    @Test func `quick add edits`() throws {
        let f = try Fixture()
        let q = try f.diary.logQuickAdd(
            name: "Cake",
            nutrients: Nutrients(kcal: 300, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: "snacks",
            day: day("2026-11-09"),
        )
        try f.diary.updateQuickAdd(entryID: q.id, name: "Birthday cake", nutrients: Nutrients(kcal: 450, proteinG: 5, carbsG: 50, fatG: 25))
        let updated = try #require(try f.diary.entry(id: q.id))
        #expect(updated.displayName == "Birthday cake")
        #expect(updated.kcal == 450)
        #expect(throws: PersistenceError.validation("quick-add entries have no quantity")) {
            try f.diary.updateQuantity(entryID: q.id, quantity: .base(1))
        }
        let food = try f.makeFood("Apple")
        let e = try f.diary.log(food: food, quantity: .base(100), slotID: "snacks", day: day("2026-11-09"))
        #expect(throws: PersistenceError.validation("not a quick-add entry")) {
            try f.diary.updateQuickAdd(entryID: e.id, name: nil, nutrients: .zero)
        }
        try f.diary.setNote(entryID: e.id, note: "green one")
        #expect(try f.diary.entry(id: e.id)?.note == "green one")
        try f.diary.setNote(entryID: e.id, note: "")
        #expect(try f.diary.entry(id: e.id)?.note == nil)
    }

    @Test func `soft delete and restore`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Nuts", kcal: 600)
        let e = try f.diary.log(food: food, quantity: .base(30), slotID: "snacks", day: d)
        try f.diary.softDelete(entryIDs: [e.id, "missing"])
        #expect(try f.diary.diary(for: d).entryCount == 0)
        #expect(try f.diary.entry(id: e.id)?.deletedAt != nil)
        try f.diary.restore(entryIDs: [e.id])
        #expect(try f.diary.diary(for: d).totals.kcal == 180)
        #expect(try f.diary.entry(id: e.id)?.revision == 3)
    }

    @Test func `undo after delete and add keeps sort orders unique`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Nuts")
        let a = try f.diary.log(food: food, quantity: .base(10), slotID: "snacks", day: d)
        let b = try f.diary.log(food: food, quantity: .base(20), slotID: "snacks", day: d)
        try f.diary.softDelete(entryIDs: [b.id])
        let c = try f.diary.log(food: food, quantity: .base(30), slotID: "snacks", day: d)
        try f.diary.restore(entryIDs: [b.id])
        let orders = try [a, b, c].map { try #require(try f.diary.entry(id: $0.id)).sortOrder }
        #expect(Set(orders).count == 3)
    }

    @Test func `undo after reorder takes a free sort order`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Nuts")
        let a = try f.diary.log(food: food, quantity: .base(10), slotID: "snacks", day: d)
        let b = try f.diary.log(food: food, quantity: .base(20), slotID: "snacks", day: d)
        let c = try f.diary.log(food: food, quantity: .base(30), slotID: "snacks", day: d)
        try f.diary.softDelete(entryIDs: [b.id])
        try f.diary.reorder(day: d, slotID: "snacks", orderedIDs: [c.id, a.id]) // c=0, a=1 (b's old slot)
        try f.diary.restore(entryIDs: [b.id])
        let orders = try [a, b, c].map { try #require(try f.diary.entry(id: $0.id)).sortOrder }
        #expect(Set(orders).count == 3)
    }

    @Test func `copy meal and day recomputes snapshot from current food`() throws {
        let f = try Fixture()
        let yesterday = day("2026-11-08"), today = day("2026-11-09")
        let oats = try f.makeFood("Oats", kcal: 380)
        let gone = try f.makeFood("Gone", kcal: 100)
        try f.diary.log(food: oats, quantity: .base(50), slotID: "breakfast", day: yesterday)
        try f.diary.log(food: gone, quantity: .base(100), slotID: "breakfast", day: yesterday)
        try f.diary.logQuickAdd(
            name: "Coffee",
            nutrients: Nutrients(kcal: 5, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: "snacks",
            day: yesterday,
        )
        try f.foods.softDelete(id: gone.id)
        var detail = try #require(try f.foods.detail(id: oats.id))
        detail.food.kcal100 = 400 // changed after logging
        try f.foods.save(detail)

        let mealIDs = try f.diary.copy(from: yesterday, slotID: "breakfast", to: today)
        #expect(mealIDs.count == 2)
        var todayDiary = try f.diary.diary(for: today)
        #expect(todayDiary.sections[0].entries.map(\.kcal) == [200, 100]) // oats re-snapshotted, deleted food kept
        #expect(try f.diary.diary(for: yesterday).sections[0].totals.kcal == 290) // source untouched

        let dayIDs = try f.diary.copy(from: yesterday, to: today, targetSlotID: "lunch")
        #expect(dayIDs.count == 3)
        todayDiary = try f.diary.diary(for: today)
        #expect(todayDiary.sections[1].entries.count == 3)

        try f.diary.softDelete(entryIDs: dayIDs) // undo
        #expect(try f.diary.diary(for: today).entryCount == 2)
    }

    @Test func `day notes`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        #expect(try f.diary.note(for: d) == nil)
        try f.diary.setDayNote(day: d, text: "", isComplete: false) // nothing to store
        #expect(try f.diary.note(for: d) == nil)
        try f.diary.setDayNote(day: d, text: "sick")
        #expect(try f.diary.note(for: d)?.text == "sick")
        try f.diary.setDayNote(day: d, text: "sick", isComplete: true)
        #expect(try f.diary.diary(for: d).note?.isComplete == true)
        try f.diary.setDayNote(day: d, text: "", isComplete: false)
        #expect(try f.diary.note(for: d) == nil)
        try f.diary.setDayNote(day: d, text: "back")
        #expect(try f.diary.note(for: d)?.text == "back")
    }

    @Test func `inactive slot shown only when it has entries`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        var slots = try f.diary.mealSlots()
        let food = try f.makeFood("Bar")
        try f.diary.log(food: food, quantity: .base(40), slotID: "snacks", day: d)
        slots[3].isActive = false
        try f.profiles.saveMealSlots(slots)
        #expect(try f.diary.mealSlots().map(\.id) == ["breakfast", "lunch", "dinner"])
        #expect(try f.diary.mealSlots(includeInactive: true).count == 4)
        #expect(try f.diary.diary(for: d).sections.map(\.slot.id) == ["breakfast", "lunch", "dinner", "snacks"])
        #expect(try f.diary.diary(for: d.next).sections.map(\.slot.id) == ["breakfast", "lunch", "dinner"])
    }

    @Test func `observation emits on change`() async throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let food = try f.makeFood("Tea", kcal: 1)
        var iterator = f.diary.observeDiary(for: d).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.entryCount == 0)
        try f.diary.log(food: food, quantity: .base(250), slotID: "snacks", day: d)
        let second = try await iterator.next()
        #expect(second?.entryCount == 1)
    }

    // MARK: Fluid

    /// A food with the given base unit, fat per 100 and fluid override.
    private func drink(
        _ f: Fixture, _ name: String, liquid: Bool = true, fat: Double = 0, countsAsFluid: Bool? = nil,
    ) throws -> Food {
        var food = Food(name: name, per100: Nutrients(kcal: 40, proteinG: 0, carbsG: 10, fatG: fat), isLiquid: liquid)
        food.countsAsFluid = countsAsFluid
        return try f.foods.save(FoodDetail(food: food)).food
    }

    @Test func `log liquid food snapshots fluid`() throws {
        let f = try Fixture()
        let cola = try drink(f, "Cola")
        let entry = try f.diary.log(food: cola, quantity: .base(330), slotID: "snacks", day: day("2026-11-09"))
        #expect(entry.fluidMl == 330)
        #expect(try f.diary.entry(id: entry.id)?.fluidMl == 330)
    }

    @Test func `log oil has no fluid`() throws {
        let f = try Fixture()
        let oil = try drink(f, "Olive oil", fat: 100)
        let entry = try f.diary.log(food: oil, quantity: .base(20), slotID: "lunch", day: day("2026-11-09"))
        #expect(entry.fluidMl == nil)
        #expect(try f.diary.entry(id: entry.id)?.fluidMl == nil)
    }

    @Test func `override on counts solid food`() throws {
        let f = try Fixture()
        let soup = try drink(f, "Soup", liquid: false, fat: 3, countsAsFluid: true)
        let entry = try f.diary.log(food: soup, quantity: .base(300), slotID: "lunch", day: day("2026-11-09"))
        #expect(try f.diary.entry(id: entry.id)?.fluidMl == 300)

        let juice = try drink(f, "Juice", countsAsFluid: false) // override off beats the automatic rule
        let off = try f.diary.log(food: juice, quantity: .base(200), slotID: "lunch", day: day("2026-11-09"))
        #expect(try f.diary.entry(id: off.id)?.fluidMl == nil)
    }

    @Test func `log all and meal plan snapshot fluid`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let cola = try drink(f, "Cola")
        let bread = try f.makeFood("Bread")
        let logged = try f.diary.logAll(
            [DiaryRepository.LogItem(food: cola, quantity: .base(330)), DiaryRepository.LogItem(food: bread, quantity: .base(50))],
            slotID: "lunch", day: d,
        )
        #expect(try logged.map { try f.diary.entry(id: $0.id)?.fluidMl } == [330, nil])

        let plans = MealPlanRepository(f.db, clock: f.clock.appClock)
        let planned = try plans.plan(food: cola, quantity: .base(250), slotID: "dinner", day: d)
        let quick = try plans.planQuickAdd(
            name: "Smoothie", nutrients: Nutrients(kcal: 200, proteinG: 2, carbsG: 40, fatG: 1), slotID: "dinner", day: d,
        )
        let ids = try plans.confirm(plannedIDs: [planned.id, quick.id])
        #expect(try ids.map { try f.diary.entry(id: $0)?.fluidMl } == [250, nil])
    }

    @Test func `update quantity scales fluid`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let cola = try drink(f, "Cola")
        let entry = try f.diary.log(food: cola, quantity: .base(330), slotID: "snacks", day: d)
        try f.diary.updateQuantity(entryID: entry.id, quantity: .base(500))
        #expect(try f.diary.entry(id: entry.id)?.fluidMl == 500)

        let bread = try f.diary.log(food: f.makeFood("Bread"), quantity: .base(50), slotID: "snacks", day: d)
        try f.diary.updateQuantity(entryID: bread.id, quantity: .base(80))
        #expect(try f.diary.entry(id: bread.id)?.fluidMl == nil)
    }

    @Test func `changing food override keeps old entries`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let cola = try drink(f, "Cola")
        let before = try f.diary.log(food: cola, quantity: .base(330), slotID: "snacks", day: d)
        var detail = try #require(try f.foods.detail(id: cola.id))
        detail.food.countsAsFluid = false
        let switchedOff = try f.foods.save(detail).food
        let after = try f.diary.log(food: switchedOff, quantity: .base(330), slotID: "snacks", day: d)
        #expect(try f.diary.entry(id: before.id)?.fluidMl == 330)
        #expect(try f.diary.entry(id: after.id)?.fluidMl == nil)

        // And the other way round: a solid food switched on doesn't turn old entries into drinks.
        let soup = try drink(f, "Soup", liquid: false)
        let solid = try f.diary.log(food: soup, quantity: .base(300), slotID: "lunch", day: d)
        var soupDetail = try #require(try f.foods.detail(id: soup.id))
        soupDetail.food.countsAsFluid = true
        try f.foods.save(soupDetail)
        #expect(try f.diary.entry(id: solid.id)?.fluidMl == nil)
    }

    @Test func `copy follows the food's current fluid setting`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let cola = try drink(f, "Cola")
        let logged = try f.diary.log(food: cola, quantity: .base(330), slotID: "snacks", day: d)
        var detail = try #require(try f.foods.detail(id: cola.id))
        detail.food.countsAsFluid = false
        try f.foods.save(detail)

        let copied = try f.diary.copy(from: d, to: d.next)
        #expect(copied.count == 1)
        #expect(try f.diary.entry(id: copied[0])?.fluidMl == nil)
        #expect(try f.diary.entry(id: logged.id)?.fluidMl == 330) // the original keeps its snapshot
    }

    @Test func `fluid rule uses the food's fat and override`() {
        let milk = Food(name: "Milk", per100: Nutrients(kcal: 64, proteinG: 3.3, carbsG: 4.8, fatG: 3.5), isLiquid: true)
        #expect(DiaryRepository.fluidMl(for: milk, baseAmount: 250) == 250)
        #expect(DiaryRepository.fluidMl(for: milk, baseAmount: 0) == nil)
        var liqueur = milk
        liqueur.fatG100 = 51
        #expect(DiaryRepository.fluidMl(for: liqueur, baseAmount: 40) == nil)
        liqueur.countsAsFluid = true
        #expect(DiaryRepository.fluidMl(for: liqueur, baseAmount: 40) == 40)
    }
}
