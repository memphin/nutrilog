import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

extension Fixture {
    var meals: MealTemplateRepository {
        MealTemplateRepository(db, clock: clock.appClock)
    }

    var checkIns: CheckInRepository {
        CheckInRepository(db, clock: clock.appClock)
    }

    var metrics: DailyMetricsRepository {
        DailyMetricsRepository(db, clock: clock.appClock)
    }

    var portability: DataPortability {
        DataPortability(db, clock: clock.appClock)
    }
}

/// 30 days of perfect logging at 2,000 kcal against a true TDEE of 2,500, ending on `end`.
func sampleEstimate(end: LocalDay = day("2026-11-08"), baseline: Double? = 2500, previous: Double? = nil) throws -> TDEEEstimate {
    var samples: [LocalDay: Double] = [:]
    for index in 0 ..< 30 {
        samples[end.adding(days: index - 29)] = 85 - Double(index) * 500 / 7700
    }
    let trend = WeightTrend.trendByDay(samples, through: end)
    let history = (0 ..< 30).map { index -> TDEEDay in
        let date = end.adding(days: index - 29)
        return TDEEDay(day: date, kcalIn: 2000, entryCount: 5, isComplete: false, weightKg: samples[date], trendKg: trend[date])
    }
    return try AdaptiveTDEE.estimate(history: history, endDay: end, baselineKcal: baseline, previousKcal: previous).get()
}

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

struct CheckInRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `accepting writes an adaptive target and the estimate in one go`() throws {
        let f = try Fixture()
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-10-01"), kcal: 2300, macros: MacroTargets(proteinG: 150, carbsG: 250, fatG: 78), origin: .formula,
        ))
        let estimate = try sampleEstimate()
        let target = Target(
            effectiveFrom: monday, kcal: 1950, macros: MacroTargets(proteinG: 150, carbsG: 190, fatG: 66), origin: .adaptive,
        )
        let record = try f.checkIns.record(
            estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted, appliedTarget: target,
            previousTargetKcal: 2300, goalChangeKgPerWeek: -0.5,
        )
        #expect(record.decision == .accepted)
        #expect(record.tdeeKcal == estimate.kcal)
        #expect(record.windowDays == 14)
        #expect(record.loggedDays == 14)
        #expect(record.confidence == estimate.confidence)
        #expect(record.appliedTargetKcal == 1950)
        #expect(record.previousTargetKcal == 2300)
        #expect(record.goalChangeKgPerWeek == -0.5)

        let current = try #require(try f.profiles.target(on: monday))
        #expect(current.kcal == 1950)
        #expect(current.origin == .adaptive)
        // Past days keep the target they had.
        #expect(try f.profiles.target(on: monday.previous)?.kcal == 2300)

        let stored = try #require(try f.checkIns.latest())
        #expect(stored == record)
        #expect(stored.estimate == estimate) // the days used survive the round trip
        #expect(stored.estimate?.days.count == 14)
    }

    @Test func `skipping keeps the target; edited stores the user's number`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let skipped = try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        #expect(skipped.appliedTargetKcal == nil)
        #expect(try f.profiles.target(on: monday) == nil)

        let next = monday.adding(days: 7)
        let custom = Target(effectiveFrom: next, kcal: 2100, macros: MacroTargets(proteinG: 150, carbsG: 220, fatG: 70), origin: .adaptive)
        let edited = try f.checkIns.record(
            estimate: sampleEstimate(end: next.previous, previous: skipped.tdeeKcal), checkInDay: next, proposedTargetKcal: 1950,
            decision: .edited, appliedTarget: custom,
        )
        #expect(edited.proposedTargetKcal == 1950)
        #expect(edited.appliedTargetKcal == 2100)
        #expect(try f.profiles.target(on: next)?.kcal == 2100)
        #expect(try f.checkIns.history().map(\.computedForDay) == [next, monday])
        #expect(try f.checkIns.history(limit: 1).count == 1)
        #expect(try f.checkIns.previousEstimateKcal(before: next) == skipped.tdeeKcal)
        #expect(try f.checkIns.previousEstimateKcal(before: monday) == nil)
        #expect(try f.checkIns.latest(onOrBefore: monday.adding(days: 3))?.computedForDay == monday)
    }

    @Test func `a second check-in on the same day replaces the first`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let first = try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        f.clock.advance(60)
        let target = Target(
            effectiveFrom: monday,
            kcal: 1950,
            macros: MacroTargets(proteinG: 150, carbsG: 190, fatG: 66),
            origin: .adaptive,
        )
        let second = try f.checkIns.record(
            estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted, appliedTarget: target,
        )
        #expect(second.id == first.id)
        #expect(second.revision == 2)
        #expect(second.createdAt == first.createdAt)
        #expect(try f.checkIns.history().count == 1)
    }

    @Test func `decision and target must agree, and a failure writes nothing`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let target = Target(effectiveFrom: monday, kcal: 1950, macros: MacroTargets(proteinG: 1, carbsG: 1, fatG: 1), origin: .adaptive)
        #expect(throws: Persistence.PersistenceError.self) {
            try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted)
        }
        #expect(throws: Persistence.PersistenceError.self) {
            try f.checkIns.record(
                estimate: estimate,
                checkInDay: monday,
                proposedTargetKcal: 1950,
                decision: .skipped,
                appliedTarget: target,
            )
        }
        #expect(try f.checkIns.history().isEmpty)
        #expect(try f.profiles.targetHistory().isEmpty)
    }

    @Test func `check-ins are exported and restored`() throws {
        let f = try Fixture()
        try f.checkIns.record(estimate: sampleEstimate(), checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        let json = try f.portability.exportJSON()
        let other = try Fixture()
        try other.portability.importJSON(json, mode: .replace)
        #expect(try other.checkIns.history() == f.checkIns.history())
        #expect(try other.portability.exportJSON() == json)
    }
}

struct FoodMergeTests {
    let d = day("2026-11-09")

    @Test func `finds duplicates by barcode and by name and brand`() throws {
        let f = try Fixture()
        let mine = try f.makeFood("Milk 2.8%", brand: "Dukat")
        let typo = try f.makeFood("milk 2,8 %", brand: "DUKAT")
        var off = FoodDetail(food: Food(name: "Trajno mlijeko", brand: "Dukat", source: .off, sourceID: "4006381333931", per100: .zero))
        off.food.dataQuality = .energyOnly
        let offCopy = try f.foods.save(off).food
        let scanned = try f.makeFood("Dukat milk", barcodes: ["4006381333931"])
        _ = try f.makeFood("Oats")
        _ = try f.makeFood("Rice")
        try f.diary.log(food: typo, quantity: .base(100), slotID: "lunch", day: d)

        let groups = try f.foods.duplicateGroups()
        #expect(groups.count == 2)
        // Groups come by their keeper's name. Suggested keeper first: complete data before an energy-only online copy…
        #expect(groups[0].map(\.food.id) == [scanned.id, offCopy.id])
        // …and the most used of two equally good foods.
        #expect(groups[1].map(\.food.id) == [typo.id, mine.id])
    }

    @Test func `merge re-points entries and meals and keeps the best data`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Milk", kcal: 60, servings: [Serving(label: "glass", grams: 250)])
        var extraDetail = FoodDetail(
            food: Food(
                name: "Milk",
                brand: "Dukat",
                per100: Nutrients(kcal: 64, proteinG: 3, carbsG: 5, fatG: 3, sugarG: 4.7, sodiumMg: 40),
            ),
            servings: [Serving(label: "glass", grams: 200), Serving(label: "carton", grams: 1000)],
            barcodes: ["4006381333931"],
        )
        extraDetail.food.nameLocal = "Mlijeko"
        let extra = try f.foods.save(extraDetail)
        try f.foods.setFavorite(id: extra.food.id, true)
        let entry = try f.diary.log(food: extra.food, quantity: .base(200), slotID: "breakfast", day: d)
        f.clock.advance(3600)
        try f.diary.log(food: keep, quantity: .base(100), slotID: "lunch", day: d)
        let carton = try #require(extra.servings.first { $0.label == "carton" })
        let meal = try f.meals.create(name: "Latte", items: [.init(foodID: extra.food.id, grams: 1000, servingID: carton.id)])
        // A row of the legacy recipe table (recipes were removed, issue #68) still follows the merge.
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO recipe_ingredient (id, recipe_id, food_id, display_name, grams, kcal_100, protein_g_100, carbs_g_100,
                    fat_g_100, created_at, updated_at)
                VALUES ('legacy', ?, ?, 'Milk', 500, 64, 3, 5, 3, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                arguments: [keep.id, extra.food.id],
            )
        }
        let totals = try f.diary.totals(for: d)
        f.clock.advance(3600)

        let merged = try f.foods.merge(keep: keep.id, remove: [extra.food.id])
        #expect(merged.food.id == keep.id)
        #expect(merged.food.kcal100 == 60) // the kept food's own values win
        #expect(merged.food.brand == "Dukat")
        #expect(merged.food.nameLocal == "Mlijeko")
        #expect(merged.food.sugarG100 == 4.7)
        #expect(merged.food.sodiumMg100 == 40)
        #expect(merged.food.isFavorite)
        #expect(merged.food.useCount == 2)
        #expect(merged.barcodes == ["4006381333931"])
        #expect(merged.servings.map(\.label) == ["glass", "carton"])
        #expect(merged.servings[0].grams == 250) // same label: the kept food's serving stays

        // History is the same, now pointing at the kept food.
        #expect(try f.diary.entry(id: entry.id)?.foodID == keep.id)
        #expect(try f.diary.entry(id: entry.id)?.kcal == entry.kcal)
        #expect(try f.diary.totals(for: d) == totals)
        let mealItem = try #require(try f.meals.detail(id: meal.id)?.items.first)
        #expect(mealItem.food.id == keep.id)
        #expect(mealItem.item.servingID == nil)
        #expect(mealItem.item.grams == 1000)
        #expect(!mealItem.isFoodDeleted)
        let legacy = try #require(try f.db.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT food_id, kcal_100 FROM recipe_ingredient WHERE id = 'legacy'")
        })
        let legacyFoodID: String? = legacy["food_id"]
        let legacyKcal: Double? = legacy["kcal_100"]
        #expect(legacyFoodID == keep.id)
        #expect(legacyKcal == 64) // snapshot untouched

        #expect(try f.foods.food(id: extra.food.id)?.deletedAt != nil)
        #expect(try f.foods.food(barcode: "4006381333931")?.food.id == keep.id)
        #expect(try f.foods.duplicateGroups().isEmpty)
    }

    @Test func `merge carries a "counts as a drink" choice to a kept food on Automatic`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Shake")
        var extra = try f.foods.save(FoodDetail(food: Food(name: "Shake", per100: Nutrients(kcal: 80, proteinG: 8, carbsG: 6, fatG: 2))))
        extra.food.countsAsFluid = false
        try f.foods.save(extra)
        #expect(try f.foods.merge(keep: keep.id, remove: [extra.food.id]).food.countsAsFluid == false)

        // The kept food's own choice wins.
        var chosen = try f.foods.save(FoodDetail(food: Food(name: "Juice", per100: Nutrients(kcal: 45, proteinG: 0, carbsG: 11, fatG: 0))))
        chosen.food.countsAsFluid = true
        chosen = try f.foods.save(chosen)
        var other = try f.foods.save(FoodDetail(food: Food(name: "Juice", per100: Nutrients(kcal: 45, proteinG: 0, carbsG: 11, fatG: 0))))
        other.food.countsAsFluid = false
        try f.foods.save(other)
        #expect(try f.foods.merge(keep: chosen.food.id, remove: [other.food.id]).food.countsAsFluid == true)
    }

    @Test func `merge is all or nothing`() throws {
        let f = try Fixture()
        let keep = try f.makeFood("Milk")
        let other = try f.makeFood("Milk", brand: "Dukat", barcodes: ["4006381333931"])
        let entry = try f.diary.log(food: other, quantity: .base(100), slotID: "lunch", day: d)
        let before = try f.portability.exportJSON()

        // The second food to remove doesn't exist: the first must not be merged either.
        #expect(throws: Persistence.PersistenceError.notFound("missing")) { try f.foods.merge(keep: keep.id, remove: [other.id, "missing"])
        }
        #expect(try f.portability.exportJSON() == before)
        #expect(try f.diary.entry(id: entry.id)?.foodID == other.id)
        #expect(try f.foods.food(id: other.id)?.deletedAt == nil)

        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: keep.id, remove: [keep.id]) }
        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: keep.id, remove: []) }
        #expect(throws: Persistence.PersistenceError.self) { try f.foods.merge(keep: "missing", remove: [other.id]) }
    }
}

struct LocalBackupsTests {
    private func makeBackups(_ f: Fixture) -> (LocalBackups, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        return (LocalBackups(directory: dir, portability: f.portability, clock: f.clock.appClock), dir)
    }

    @Test func `weekly backups, newest seven kept`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try backups.list().isEmpty)

        let first = try #require(try backups.backupIfDue())
        #expect(first.createdAt == Date(timeIntervalSince1970: f.clock.now.timeIntervalSince1970.rounded(.down)))
        #expect(first.sizeBytes > 100)
        f.clock.advance(6 * 86400)
        #expect(try backups.backupIfDue() == nil) // not a week yet
        f.clock.advance(86400)
        #expect(try backups.backupIfDue() != nil)
        #expect(try backups.list().count == 2)

        for _ in 0 ..< 8 {
            f.clock.advance(7 * 86400)
            try backups.backupIfDue()
        }
        let kept = try backups.list()
        #expect(kept.count == LocalBackups.keep)
        #expect(kept.map(\.createdAt) == kept.map(\.createdAt).sorted(by: >))
        #expect(!kept.contains { $0.url == first.url }) // the oldest are gone
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 7)
    }

    @Test func `manual backup, other files ignored, delete`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manual = try backups.backupNow()
        f.clock.advance(5)
        let second = try backups.backupNow() // "back up now" ignores the weekly rhythm
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("vitalion-backup-garbage.json"))
        #expect(try backups.list().map(\.url.lastPathComponent) == [second.url.lastPathComponent, manual.url.lastPathComponent])
        try backups.delete(manual)
        #expect(try backups.list().count == 1)
        #expect(LocalBackups.date(fromFileName: "vitalion-backup-20261109T140312Z.json") == Timestamp.date("2026-11-09T14:03:12Z"))
        #expect(try LocalBackups
            .fileName(for: #require(Timestamp.date("2026-11-09T14:03:12.900Z"))) == "vitalion-backup-20261109T140312Z.json")
        // Backups from before the rename (Nutrilog) are still listed and restorable.
        #expect(LocalBackups.date(fromFileName: "nutrilog-backup-20261109T140312Z.json") == Timestamp.date("2026-11-09T14:03:12Z"))
        let legacy = dir.appendingPathComponent("nutrilog-backup-20200101T000000Z.json")
        try FileManager.default.copyItem(at: second.url, to: legacy)
        let listed = try backups.list()
        #expect(listed.map(\.url.lastPathComponent) == [second.url.lastPathComponent, legacy.lastPathComponent])
        _ = try backups.restore(#require(listed.last))
    }

    @Test func `restore brings the data back`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rice = try f.makeFood("Rice", kcal: 130)
        try f.diary.log(food: rice, quantity: .base(200), slotID: "lunch", day: day("2026-11-09"))
        let backup = try backups.backupNow()

        f.clock.advance(3600)
        try f.foods.softDelete(id: rice.id)
        try f.diary.log(food: rice, quantity: .base(900), slotID: "dinner", day: day("2026-11-09"))
        try backups.restore(backup)
        #expect(try f.diary.totals(for: day("2026-11-09")).kcal == 260)
        #expect(try f.foods.food(id: rice.id)?.deletedAt == nil)
    }
}

struct Phase3QueryTests {
    @Test func `day summaries: totals, entry counts and the complete mark`() throws {
        let f = try Fixture()
        let d = day("2026-11-05")
        let rice = try f.makeFood("Rice", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3)
        try f.diary.log(food: rice, quantity: .base(200), slotID: "lunch", day: d)
        let removed = try f.diary.log(food: rice, quantity: .base(100), slotID: "dinner", day: d)
        try f.diary.softDelete(entryIDs: [removed.id])
        try f.diary.logQuickAdd(name: nil, nutrients: Nutrients(kcal: 240, proteinG: 0, carbsG: 0, fatG: 0), slotID: "snacks", day: d)
        try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: d.adding(days: 2))
        try f.diary.setDayNote(day: d.adding(days: 2), text: "", isComplete: true)
        try f.diary.setDayNote(day: d.adding(days: 3), text: "fasting", isComplete: true) // complete with no entries
        try f.diary.setDayNote(day: d.adding(days: 4), text: "just a note") // not a logged day
        try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: d.adding(days: 30)) // outside the range

        let rows = try f.diary.daySummaries(in: d.previous ... d.adding(days: 10))
        #expect(rows.map(\.day) == [d, d.adding(days: 2), d.adding(days: 3)])
        #expect(rows[0].totals.kcal == 500)
        #expect(rows[0].entryCount == 2)
        #expect(!rows[0].isComplete)
        #expect(try rows[0].totals == (f.diary.totals(for: d)))
        #expect(rows[1].isComplete)
        #expect(rows[1].entryCount == 1)
        #expect(rows[2] == DiaryDaySummary(day: d.adding(days: 3), totals: .zero, entryCount: 0, isComplete: true))
        #expect(try f.diary.firstLoggedDay() == d)
        #expect(try Fixture().diary.firstLoggedDay() == nil)
    }

    @Test func `weight trend is stored on existing rows and survives a Health refresh`() throws {
        let f = try Fixture()
        let d = day("2026-11-05")
        try f.metrics.upsert([DailyHealthMetrics(day: d, steps: 8000, weightKg: 80), DailyHealthMetrics(day: d.next, steps: 9000)])
        f.clock.advance(60)
        #expect(try f.metrics.setWeightTrends([d: 80, d.next: 80.1, d.adding(days: 2): 80.2]) == 2) // no row for the third day
        let stored = try f.metrics.metrics(in: d ... d.adding(days: 2))
        #expect(stored.map(\.weightTrendKg) == [80, 80.1])
        #expect(stored.map(\.revision) == [2, 2])
        #expect(stored[0].updatedAt == f.clock.now)
        // Same values again: nothing changes.
        f.clock.advance(60)
        #expect(try f.metrics.setWeightTrends([d: 80, d.next: 80.1]) == 0)
        #expect(try f.metrics.metrics(on: d)?.revision == 2)
        // A Health refresh with new values keeps the trend.
        try f.metrics.upsert([DailyHealthMetrics(day: d, steps: 8500, weightKg: 80)])
        #expect(try f.metrics.metrics(on: d)?.weightTrendKg == 80)
        #expect(try f.metrics.setWeightTrends([:]) == 0)
    }

    @Test func `target timeline resolves the target of any day`() throws {
        let f = try Fixture()
        let macros = MacroTargets(proteinG: 100, carbsG: 200, fatG: 60)
        try f.profiles.setTarget(Target(effectiveFrom: day("2026-10-01"), kcal: 2200, macros: macros, origin: .manual))
        try f.profiles.setTarget(Target(effectiveFrom: day("2026-11-01"), kcal: 2000, macros: macros, origin: .adaptive))
        let timeline = try f.profiles.targetTimeline()
        #expect(timeline.value(on: day("2026-09-30")) == nil)
        #expect(timeline.value(on: day("2026-10-20"))?.kcal == 2200)
        #expect(timeline.value(on: day("2026-11-09"))?.kcal == 2000)
    }

    @Test func `migration 007 adds the check-in detail columns to an existing database`() throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        for name in Migrator.migrations.prefix(6) {
            old.registerMigration(name) { db in try db.execute(sql: Migrator.sql(named: name)) }
        }
        try old.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO tdee_estimate (id, computed_for_day, window_days, logged_days, mean_intake_kcal, trend_start_kg,
                trend_end_kg, tdee_kcal, confidence, created_at, updated_at)
            VALUES ('old', '2026-11-02', 14, 12, 2100, 81, 80.5, 2380, 'medium', '2026-11-02T08:00:00.000Z', '2026-11-02T08:00:00.000Z')
            """)
        }
        let db = try AppDatabase(queue)
        let record = try #require(try CheckInRepository(db).latest())
        #expect(record.id == "old")
        #expect(record.tdeeKcal == 2380)
        #expect(record.decision == nil)
        #expect(record.estimate == nil)
        #expect(record.rawTDEEKcal == nil)
        #expect(DataPortability.schemaVersion >= 7)
    }
}
