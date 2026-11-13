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

struct PortabilityFixesTests {
    @Test func `merge into a fresh install takes the edited profile and slots over the seeds`() throws {
        let source = try Fixture()
        var profile = try source.profiles.profile()
        profile.heightCm = 182
        profile.birthDate = day("1988-03-14")
        profile.sex = .female
        profile.goalMode = .lose
        profile.waterGoalMl = 3000
        profile.checkinWeekday = 7
        try source.profiles.save(profile)
        var slots = try source.diary.mealSlots()
        slots[0].name = "Morning"
        slots.swapAt(1, 2)
        try source.profiles.saveMealSlots(slots)
        let json = try DataPortability(source.db, clock: source.clock.appClock).exportJSON()

        // A brand-new install: its seeds carry a later `updated_at` than every row of the file.
        let fresh = try Fixture()
        try fresh.db.writer.write { db in
            try db.execute(sql: "UPDATE profile SET updated_at = '2099-01-01T00:00:00.000Z'")
            try db.execute(sql: "UPDATE meal_slot SET updated_at = '2099-01-01T00:00:00.000Z'")
        }
        let summary = try DataPortability(fresh.db).importJSON(json, mode: .merge)
        #expect(summary.updated == 4) // the profile, the renamed slot and the two swapped ones

        let merged = try fresh.profiles.profile()
        #expect(merged.heightCm == 182)
        #expect(merged.birthDate == day("1988-03-14"))
        #expect(merged.sex == .female)
        #expect(merged.goalMode == .lose)
        #expect(merged.waterGoalMl == 3000)
        #expect(merged.checkinWeekday == 7)
        #expect(try fresh.diary.mealSlots().map(\.name) == ["Morning", "Dinner", "Lunch", "Snacks"])
    }

    @Test func `an edited local profile still wins over an older file`() throws {
        let source = try Fixture()
        var profile = try source.profiles.profile()
        profile.heightCm = 182
        try source.profiles.save(profile)
        let json = try DataPortability(source.db, clock: source.clock.appClock).exportJSON()

        let local = try Fixture()
        local.clock.advance(3600)
        var mine = try local.profiles.profile()
        mine.heightCm = 170
        try local.profiles.save(mine) // revision 2, newer than the file
        try DataPortability(local.db).importJSON(json, mode: .merge)
        #expect(try local.profiles.profile().heightCm == 170)
    }

    @Test func `csv quotes fields with windows line breaks`() {
        #expect(DataPortability.csv([["a\r\nb", "c"]]) == "\"a\r\nb\",c\r\n")
        #expect(DataPortability.csv([["a\rb"]]) == "\"a\rb\"\r\n")
        #expect(DataPortability.csv([["plain"]]) == "plain\r\n")
    }
}

/// Food entries stored with 0 g (legacy or imported) keep their own snapshot when copied, planned or confirmed.
struct ZeroGramEntryTests {
    private func plans(_ f: Fixture) -> MealPlanRepository {
        MealPlanRepository(f.db, clock: f.clock.appClock)
    }

    private func zeroGramEntry(_ f: Fixture, day d: LocalDay) throws -> DiaryEntry {
        let soup = try f.makeFood("Soup", kcal: 50)
        let entry = try f.diary.log(food: soup, quantity: .base(300), slotID: "lunch", day: d) // 150 kcal
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE diary_entry SET grams = 0, display_name = 'Old soup' WHERE id = ?", arguments: [entry.id])
        }
        return try #require(try f.diary.entry(id: entry.id))
    }

    @Test func `copying a 0 g entry keeps its snapshot`() throws {
        let f = try Fixture()
        let source = try zeroGramEntry(f, day: day("2026-11-09"))
        let ids = try f.diary.copy(from: day("2026-11-09"), to: day("2026-11-10"))
        let copy = try #require(try f.diary.entry(id: ids[0]))
        #expect(copy.kcal == 150)
        #expect(copy.nutrients == source.nutrients)
        #expect(copy.displayName == "Old soup")
    }

    @Test func `planning from a 0 g entry keeps its snapshot`() throws {
        let f = try Fixture()
        _ = try zeroGramEntry(f, day: day("2026-11-09"))
        let ids = try plans(f).copyToPlan(from: day("2026-11-09"), to: day("2026-11-12"))
        let planned = try #require(try plans(f).entry(id: ids[0]))
        #expect(planned.kcal == 150)
        #expect(planned.displayName == "Old soup")
    }

    @Test func `confirming a 0 g plan keeps its estimate`() throws {
        let f = try Fixture()
        let soup = try f.makeFood("Soup", kcal: 50)
        let planned = try plans(f).plan(food: soup, quantity: .base(300), slotID: "lunch", day: day("2026-11-12"))
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE planned_entry SET grams = 0 WHERE id = ?", arguments: [planned.id])
        }
        let ids = try plans(f).confirm(plannedIDs: [planned.id])
        let entry = try #require(try f.diary.entry(id: ids[0]))
        #expect(entry.kcal == 150)
        #expect(entry.grams == 0)
    }
}

/// The bundled index and online USDA search share FDC ids: one food, stored once.
struct BundledUSDADeduplicationTests {
    private let raw = BundledFood(
        id: "b1", sourceID: "171705", name: "Bananas, raw", per100: Nutrients(kcal: 89, proteinG: 1.1, carbsG: 22.8, fatG: 0.3),
    )

    private func usda() -> FoodDetail {
        FoodDetail(food: Food(name: "Bananas, raw", source: .usda, sourceID: "171705", per100: raw.per100))
    }

    private func activeFoods(_ f: Fixture) throws -> Int {
        try f.db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food WHERE deleted_at IS NULL") ?? 0 }
    }

    @Test func `online USDA copy reuses the local bundled food`() throws {
        let f = try Fixture()
        let bundled = try f.foods.localCopy(of: raw)
        let saved = try f.foods.saveCopy(usda())
        #expect(saved.food.id == bundled.id)
        #expect(try activeFoods(f) == 1)
    }

    @Test func `bundled copy reuses the online USDA food`() throws {
        let f = try Fixture()
        let saved = try f.foods.saveCopy(usda())
        let copy = try f.foods.localCopy(of: raw)
        #expect(copy.id == saved.food.id)
        #expect(try activeFoods(f) == 1)

        // A deleted bundled copy isn't revived while the USDA food is active.
        let other = try Fixture()
        let old = try other.foods.localCopy(of: raw)
        try other.foods.softDelete(id: old.id)
        let online = try other.foods.saveCopy(usda())
        #expect(online.food.id != old.id)
        #expect(try other.foods.localCopy(of: raw).id == online.food.id)
        #expect(try activeFoods(other) == 1)
    }

    @Test func `search hides the bundled row once the USDA food is local`() throws {
        let f = try Fixture()
        let index = try makeBundledIndex(rows: [("b1", "171705", "Bananas, raw", 89)])
        let search = FoodSearch(f.db, bundled: index)
        try f.foods.saveCopy(usda())
        let results = try search.search("banana")
        #expect(results.map(\.source) == [.usda])
    }
}
