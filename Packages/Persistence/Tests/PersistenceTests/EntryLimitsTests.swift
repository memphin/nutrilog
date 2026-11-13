import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Amount limits (pasted `inf` / 23-digit numbers) and the exporter's handling of rows stored before them.
struct EntryLimitsTests {
    private func plans(_ f: Fixture) -> MealPlanRepository {
        MealPlanRepository(f.db, clock: f.clock.appClock)
    }

    private func meals(_ f: Fixture) -> MealTemplateRepository {
        MealTemplateRepository(f.db, clock: f.clock.appClock)
    }

    private let tooLarge = PersistenceError.validation("That amount is too large.")
    private let notANumber = PersistenceError.validation("That amount is not a number.")

    @Test func `public limits`() {
        #expect(EntryLimits.maxAmount == 100_000)
        #expect(EntryLimits.maxKcal == 100_000)
        #expect(EntryLimits.maxMacroGrams == 100_000)
    }

    @Test func `food entries reject non-finite and too large amounts`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let d = day("2026-11-09")
        #expect(throws: notANumber) { try f.diary.log(food: rice, quantity: .base(.infinity), slotID: "lunch", day: d) }
        #expect(throws: tooLarge) { try f.diary.log(food: rice, quantity: .base(1e20), slotID: "lunch", day: d) }
        #expect(throws: PersistenceError.validation("amount must be greater than zero")) {
            try f.diary.log(food: rice, quantity: .base(.nan), slotID: "lunch", day: d)
        }
        #expect(throws: tooLarge) {
            try f.diary.logAll([.init(food: rice, quantity: .base(100)), .init(food: rice, quantity: .base(200_000))], slotID: "lunch", day: d)
        }
        #expect(try f.diary.diary(for: d).entryCount == 0) // all or nothing

        let entry = try f.diary.log(food: rice, quantity: .base(EntryLimits.maxAmount), slotID: "lunch", day: d) // the limit itself is fine
        #expect(throws: notANumber) { try f.diary.updateQuantity(entryID: entry.id, quantity: .base(.infinity)) }
        #expect(throws: tooLarge) { try f.diary.updateQuantity(entryID: entry.id, quantity: .base(100_001)) }
        #expect(try f.diary.entry(id: entry.id)?.grams == EntryLimits.maxAmount)
    }

    @Test func `quick adds reject non-finite and too large nutrients`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let huge = Nutrients(kcal: 12_345_678_901_234_567_890_123, proteinG: 0, carbsG: 0, fatG: 0)
        #expect(throws: tooLarge) { try f.diary.logQuickAdd(name: nil, nutrients: huge, slotID: "lunch", day: d) }
        #expect(throws: tooLarge) {
            try f.diary.logQuickAdd(name: nil, nutrients: Nutrients(kcal: 10, proteinG: 0, carbsG: 200_000, fatG: 0), slotID: "lunch", day: d)
        }
        #expect(throws: notANumber) {
            try f.diary.logQuickAdd(name: nil, nutrients: Nutrients(kcal: .infinity, proteinG: 0, carbsG: 0, fatG: 0), slotID: "lunch", day: d)
        }
        #expect(throws: notANumber) { // optional nutrients are checked when present
            try f.diary.logQuickAdd(
                name: nil, nutrients: Nutrients(kcal: 10, proteinG: 0, carbsG: 0, fatG: 0, sodiumMg: .nan), slotID: "lunch", day: d,
            )
        }
        #expect(try f.diary.diary(for: d).entryCount == 0)

        let entry = try f.diary.logQuickAdd(name: nil, nutrients: Nutrients(kcal: 500, proteinG: 0, carbsG: 0, fatG: 0), slotID: "lunch", day: d)
        #expect(throws: tooLarge) { try f.diary.updateQuickAdd(entryID: entry.id, name: nil, nutrients: huge) }
        #expect(try f.diary.entry(id: entry.id)?.kcal == 500)
    }

    @Test func `plans reject non-finite and too large values`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let d = day("2026-11-12")
        #expect(throws: notANumber) { try plans(f).plan(food: rice, quantity: .base(.infinity), slotID: "lunch", day: d) }
        #expect(throws: tooLarge) {
            try plans(f).planQuickAdd(name: nil, nutrients: Nutrients(kcal: 1e20, proteinG: 0, carbsG: 0, fatG: 0), slotID: "lunch", day: d)
        }
        let planned = try plans(f).plan(food: rice, quantity: .base(100), slotID: "lunch", day: d)
        #expect(throws: tooLarge) { try plans(f).updateQuantity(plannedID: planned.id, quantity: .base(1e20)) }
        #expect(try plans(f).pending(for: d).map(\.grams) == [100])
    }

    @Test func `saved meals and water reject too large amounts`() throws {
        let f = try Fixture()
        let oats = try f.makeFood("Oats")
        #expect(throws: notANumber) { try meals(f).create(name: "Big", items: [.init(foodID: oats.id, grams: .infinity)]) }
        let meal = try meals(f).create(name: "Usual", items: [.init(foodID: oats.id, grams: 50)])
        #expect(throws: tooLarge) { try meals(f).setItems(id: meal.id, items: [.init(foodID: oats.id, grams: 1e20)]) }
        #expect(try meals(f).detail(id: meal.id)?.items.map(\.item.grams) == [50])

        #expect(throws: tooLarge) { try f.water.add(ml: 1e20, day: day("2026-11-09")) }
        #expect(throws: PersistenceError.validation("amount must be greater than zero")) { try f.water.add(ml: .infinity, day: day("2026-11-09")) }
        #expect(try f.water.add(ml: 500, day: day("2026-11-09")).ml == 500)
    }

    @Test func `the food editor rejects non-finite values`() throws {
        let f = try Fixture()
        #expect(throws: notANumber) { try f.makeFood("Broken", kcal: .infinity) }
        #expect(throws: tooLarge) { try f.makeFood("Broken", servings: [Serving(label: "tub", grams: 1e20)]) }
        #expect(try f.foods.customFoods().isEmpty)
    }

    @Test func `export survives non-finite values stored earlier and still restores`() throws {
        let f = try Fixture()
        let rice = try f.makeFood("Rice", kcal: 130)
        let entry = try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: day("2026-11-09"))
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE diary_entry SET kcal = ?, fiber_g = ?, protein_g = ? WHERE id = ?",
                arguments: [Double.infinity, Double.infinity, -Double.infinity, entry.id],
            )
        }
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: [[String: Any]]])
        let row = try #require(tables["diary_entry"]?.first)
        #expect(row["kcal"] as? Double == EntryLimits.maxAmount) // NOT NULL: clamped
        #expect(row["protein_g"] as? Double == -EntryLimits.maxAmount)
        #expect(row["fiber_g"] is NSNull) // nullable: null

        let target = try Fixture()
        try DataPortability(target.db).importJSON(json, mode: .replace)
        #expect(try target.diary.entry(id: entry.id)?.kcal == EntryLimits.maxAmount)
        #expect(try target.diary.entry(id: entry.id)?.fiberG == nil)
    }
}

struct PersistenceErrorDescriptionTests {
    @Test func `errors read as sentences in alerts`() {
        #expect(PersistenceError.validation("That amount is too large.").localizedDescription == "That amount is too large.")
        #expect(PersistenceError.validation("amount must be greater than zero").localizedDescription == "Amount must be greater than zero.")
        for error in [
            PersistenceError.notFound("x"), .invalidBarcode("1"), .barcodeInUse(barcode: "1", foodID: "f"), .validation(""),
        ] {
            #expect(!error.localizedDescription.isEmpty)
            #expect(!error.localizedDescription.contains("PersistenceError"))
            #expect(!error.localizedDescription.contains("operation couldn"))
        }
    }
}
