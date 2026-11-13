import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct ProfileRepositoryTests {
    @Test func `profile defaults and save`() throws {
        let f = try Fixture()
        var profile = try f.profiles.profile()
        #expect(profile.activityLevel == .light)
        #expect(profile.goalMode == .maintain)
        #expect(profile.waterGoalMl == 2500)
        profile.heightCm = 180
        profile.birthDate = day("1990-05-01")
        profile.sex = .male
        profile.activityLevel = .veryActive
        try f.profiles.save(profile)
        let saved = try f.profiles.profile()
        #expect(saved.activityLevel == .veryActive)
        #expect(saved.birthDate == day("1990-05-01"))
        #expect(saved.revision == 2)
    }

    @Test func `targets are versioned by effective day`() throws {
        let f = try Fixture()
        #expect(try f.profiles.target(on: day("2026-11-09")) == nil)
        let macros = MacroTargets(proteinG: 150, carbsG: 200, fatG: 70)
        let first = try f.profiles.setTarget(Target(effectiveFrom: day("2026-11-01"), kcal: 2200, macros: macros, origin: .formula))
        try f.profiles.setTarget(Target(effectiveFrom: day("2026-11-09"), kcal: 2000, macros: macros, origin: .manual))
        #expect(try f.profiles.target(on: day("2026-10-31")) == nil)
        #expect(try f.profiles.target(on: day("2026-11-05"))?.kcal == 2200) // past days keep their target
        #expect(try f.profiles.target(on: day("2026-11-09"))?.kcal == 2000)
        #expect(try f.profiles.target(on: day("2027-01-01"))?.kcal == 2000)

        // Same effective day → replaced in place.
        let replaced = try f.profiles.setTarget(Target(effectiveFrom: day("2026-11-01"), kcal: 2300, macros: macros, origin: .manual))
        #expect(replaced.id == first.id)
        #expect(replaced.revision == 2)
        #expect(try f.profiles.targetHistory().map(\.kcal) == [2000, 2300])
        #expect(try f.profiles.target(on: day("2026-11-05"))?.macros == macros)
    }

    @Test func `manual weights`() throws {
        let f = try Fixture()
        #expect(try f.weights.latest() == nil)
        try f.weights.add(kg: 82.4, measuredAt: f.clock.now.addingTimeInterval(-86400))
        try f.weights.add(kg: 82.0, bodyFatPct: 18)
        #expect(try f.weights.latest()?.kg == 82.0)
        #expect(throws: PersistenceError.validation("weight out of range")) { try f.weights.add(kg: 0) }
    }

    @Test func `settings round trip`() throws {
        let f = try Fixture()
        #expect(try f.profiles.setting("showKJ", as: Bool.self) == nil)
        try f.profiles.setSetting("showKJ", true)
        try f.profiles.setSetting("waterSizes", [200, 330, 500])
        #expect(try f.profiles.setting("showKJ", as: Bool.self) == true)
        #expect(try f.profiles.setting("waterSizes", as: [Int].self) == [200, 330, 500])
    }

    @Test func `meal slot editing`() throws {
        let f = try Fixture()
        var slots = try f.diary.mealSlots()
        slots[0].name = "Morning"
        slots.swapAt(1, 2)
        slots.append(MealSlot(name: "Pre-workout", sortOrder: 99, defaultStartHour: 18))
        try f.profiles.saveMealSlots(slots)
        let saved = try f.diary.mealSlots()
        #expect(saved.map(\.name) == ["Morning", "Dinner", "Lunch", "Snacks", "Pre-workout"])
        #expect(saved.map(\.sortOrder) == [0, 1, 2, 3, 4])
        #expect(saved[3].revision == 1) // untouched row not rewritten
    }

    @Test func `observe profile and target`() async throws {
        let f = try Fixture()
        var profiles = f.profiles.observeProfile().makeAsyncIterator()
        #expect(try await profiles.next()??.heightCm == nil)
        var targets = f.profiles.observeTarget(on: day("2026-11-09")).makeAsyncIterator()
        #expect(try await targets.next()! == nil)
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-11-09"),
            kcal: 1800,
            macros: MacroTargets(proteinG: 1, carbsG: 1, fatG: 1),
            origin: .manual,
        ))
        #expect(try await targets.next()??.kcal == 1800)
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
}

struct DataPortabilityTests {
    func populated() throws -> Fixture {
        let f = try Fixture()
        let bread = try f.makeFood(
            "Kruh, \"domaći\"", kcal: 250, brand: "Pekara", servings: [Serving(label: "slice", grams: 30)], barcodes: ["3850104003455"],
        )
        let detail = try #require(try f.foods.detail(id: bread.id))
        try f.diary.log(
            food: bread,
            quantity: .servings(count: 2, serving: detail.servings[0].size),
            servingID: detail.servings[0].id,
            slotID: "breakfast",
            day: day("2026-11-08"),
        )
        let deleted = try f.diary.log(food: bread, quantity: .base(10), slotID: "lunch", day: day("2026-11-08"))
        try f.diary.softDelete(entryIDs: [deleted.id]) // tombstone must be exported too
        try f.diary.logQuickAdd(
            name: "Pizza, slice",
            nutrients: Nutrients(kcal: 285.5, proteinG: 12, carbsG: 36, fatG: 10, sodiumMg: 640),
            slotID: "dinner",
            day: day("2026-11-08"),
        )
        try f.diary.setDayNote(day: day("2026-11-08"), text: "line1\nline2", isComplete: true)
        try f.weights.add(kg: 81.25, bodyFatPct: 17.5)
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-11-01"),
            kcal: 2100,
            macros: MacroTargets(proteinG: 150, carbsG: 210, fatG: 70),
            origin: .formula,
        ))
        try f.profiles.setSetting("showKJ", false)
        try f.trainingDays.setSchedule(weekdays: [2, 4, 6], boostPercent: 15, effectiveFrom: day("2026-11-01"))
        try f.trainingDays.setTraining(true, on: day("2026-11-08"))
        try f.trainingDays.setTraining(false, on: day("2026-11-04"))
        try f.trainingDays.clearOverride(on: day("2026-11-04")) // tombstone must be exported too
        return f
    }

    @Test func `json round trip is byte identical`() throws {
        let source = try populated()
        let json = try DataPortability(source.db, clock: source.clock.appClock).exportJSON()

        let target = try Fixture()
        let summary = try DataPortability(target.db, clock: source.clock.appClock).importJSON(json, mode: .replace)
        #expect(summary.inserted > 10)
        #expect(summary.updated == 0)
        let again = try DataPortability(target.db, clock: source.clock.appClock).exportJSON()
        #expect(again == json)

        // FTS index is rebuilt by triggers on import.
        #expect(try FoodSearch(target.db, bundled: nil).search("domaci").count == 1)
        #expect(try target.diary.diary(for: day("2026-11-08")).totals.kcal == 150 + 285.5)
        let training = try target.trainingDays.trainingDays(in: day("2026-11-01") ... day("2026-11-30"))
        #expect(training == (try source.trainingDays.trainingDays(in: day("2026-11-01") ... day("2026-11-30"))))
        #expect(training.isTraining(day("2026-11-08"))) // a Sunday, switched on
        #expect(training.isTraining(day("2026-11-04"))) // override cleared: back to its Wednesday
        #expect(training.boost(on: day("2026-11-02")) == 15)
    }

    @Test func `export contains tombstones and schema version`() throws {
        let f = try populated()
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["format"] as? String == "vitalion-export")
        #expect(object["schemaVersion"] as? Int == Migrator.migrations.count)
        let tables = try #require(object["tables"] as? [String: [[String: Any]]])
        #expect(tables["diary_entry"]?.count == 3)
        #expect(tables["diary_entry"]?.contains { !($0["deleted_at"] is NSNull) } == true)
        #expect(tables["off_product_cache"] == nil)
    }

    @Test func `merge is last writer wins`() throws {
        let f = try populated()
        let portability = DataPortability(f.db, clock: f.clock.appClock)
        let json = try portability.exportJSON()

        // Local edit after the export (newer) and a new local food.
        f.clock.advance(3600)
        let foodID = try #require(try f.foods.customFoods().first?.id)
        var detail = try #require(try f.foods.detail(id: foodID))
        detail.food.name = "Local newer name"
        try f.foods.save(detail)
        try f.makeFood("Only local")

        let summary = try portability.importJSON(json, mode: .merge)
        #expect(summary.inserted == 0)
        #expect(summary.updated == 0) // file rows are all older or equal
        #expect(try f.foods.food(id: foodID)?.name == "Local newer name")
        #expect(try f.foods.customFoods().count == 2)
        #expect(try f.foods.detail(id: foodID)?.servings.count == 1) // children kept (UPDATE, not REPLACE)

        // Now the file is newer than local → file wins.
        let other = try Fixture()
        f.clock.advance(3600)
        detail.food.name = "File newest name"
        try f.foods.save(detail)
        let newer = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        try DataPortability(other.db).importJSON(json, mode: .replace)
        let merged = try DataPortability(other.db).importJSON(newer, mode: .merge)
        #expect(merged.updated >= 1)
        #expect(merged.inserted >= 1) // "Only local" food comes in
        #expect(try other.foods.food(id: foodID)?.name == "File newest name")
    }

    @Test func `rejects foreign and newer files`() throws {
        let f = try Fixture()
        let p = DataPortability(f.db)
        #expect(throws: DataPortability.ImportError.notAnExport) { try p.importJSON(Data("{}".utf8), mode: .merge) }
        #expect(throws: DataPortability.ImportError.notAnExport) {
            try p.importJSON(Data(#"{"format":"other","schemaVersion":1,"exportedAt":"x","tables":{}}"#.utf8), mode: .merge)
        }
        #expect(throws: DataPortability.ImportError.newerSchema(file: 99, supported: Migrator.migrations.count)) {
            try p.importJSON(Data(#"{"format":"vitalion-export","schemaVersion":99,"exportedAt":"x","tables":{}}"#.utf8), mode: .merge)
        }
        // Files exported before the rename (Nutrilog) are still recognised as exports.
        #expect(throws: DataPortability.ImportError.newerSchema(file: 99, supported: Migrator.migrations.count)) {
            try p.importJSON(Data(#"{"format":"nutrilog-export","schemaVersion":99,"exportedAt":"x","tables":{}}"#.utf8), mode: .merge)
        }
        #expect(throws: DataPortability.ImportError.unknownTable("evil")) {
            try p.importJSON(
                Data(#"{"format":"vitalion-export","schemaVersion":1,"exportedAt":"x","tables":{"evil":[]}}"#.utf8),
                mode: .merge,
            )
        }
    }

    @Test func `replace rejects a partial file`() throws {
        let f = try Fixture()
        let p = DataPortability(f.db)
        for tables in [#"{"food":[]}"#, #"{"food":[],"profile":[],"meal_slot":[]}"#] {
            #expect(throws: DataPortability.ImportError.incompleteBackup) {
                try p.importJSON(
                    Data(#"{"format":"vitalion-export","schemaVersion":1,"exportedAt":"x","tables":\#(tables)}"#.utf8),
                    mode: .replace,
                )
            }
        }
        _ = try f.profiles.profile() // nothing was wiped
    }

    @Test func `merge skips unique clashes but rejects invalid rows`() throws {
        let f = try Fixture()
        try f.db.writer.write { db in
            try db.execute(sql: """
            INSERT INTO healthkit_link (id, owner_table, owner_id, hk_type, hk_uuid, created_at)
            VALUES ('local', 'weight_entry', 'w1', 'HKQuantityTypeIdentifierBodyMass', 'HK-1', '2026-11-09T10:00:00Z')
            """)
        }
        func file(_ id: String, owner: String, uuid: String) -> Data {
            Data(#"{"format":"vitalion-export","schemaVersion":1,"exportedAt":"x","tables":{"healthkit_link":[{"id":"\#(id)","owner_table":"\#(owner)","owner_id":"w2","hk_type":"t","hk_uuid":"\#(uuid)","created_at":"2026-11-09T11:00:00Z"}]}}"#.utf8)
        }
        let p = DataPortability(f.db)
        let clash = try p.importJSON(file("remote", owner: "weight_entry", uuid: "HK-1"), mode: .merge)
        #expect(clash.inserted == 0)
        #expect(clash.skipped == 1)
        let fresh = try p.importJSON(file("remote2", owner: "weight_entry", uuid: "HK-2"), mode: .merge)
        #expect(fresh.inserted == 1)
        // A CHECK violation is a broken file, not a conflict: the import fails instead of silently dropping it.
        #expect(throws: (any Error).self) { try p.importJSON(file("bad", owner: "nonsense", uuid: "HK-3"), mode: .merge) }
    }

    @Test func `csv neutralizes spreadsheet formulas`() {
        #expect(DataPortability.neutralizeFormula("=HYPERLINK(\"x\")") == "'=HYPERLINK(\"x\")")
        #expect(DataPortability.neutralizeFormula("@cmd") == "'@cmd")
        #expect(DataPortability.neutralizeFormula("-5") == "-5")
        #expect(DataPortability.neutralizeFormula("Banana") == "Banana")
        #expect(DataPortability.neutralizeFormula("  =1+1") == "'  =1+1")
        #expect(DataPortability.neutralizeFormula("＝1+1") == "'＝1+1")
        #expect(DataPortability.csv([["=a,b"]]) == "\"'=a,b\"\r\n") // neutralized, then RFC 4180 quoted
    }

    @Test func `csv export`() throws {
        let f = try populated()
        let files = try DataPortability(f.db).exportCSV()
        let diary = try #require(files["diary.csv"])
        let lines = diary.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 3) // header + 2 active entries
        #expect(lines[0].hasPrefix("day,meal,food,amount,unit"))
        #expect(lines[1] == #"2026-11-08,Breakfast,"Kruh, ""domaći""",60,g,2 × slice,150,6,6,1.2,,,,,,0,"#)
        #expect(lines[2].hasPrefix(#"2026-11-08,Dinner,"Pizza, slice",,,,285.5,12,36,10,,,,640,,1,"#))
        let weights = try #require(files["weights.csv"])
        #expect(weights.contains(",81.25,17.5,manual"))
    }

    @Test func `export of 5000 entries is fast`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Bulk")
        try f.db.writer.write { db in
            let now = Timestamp.string(f.clock.now)
            for i in 0 ..< 5000 {
                try db.execute(sql: """
                INSERT INTO diary_entry (id, day, meal_slot_id, food_id, display_name, grams, kcal, protein_g, carbs_g, fat_g, logged_at, created_at, updated_at)
                VALUES (?, '2026-01-01', 'lunch', ?, 'Bulk', 100, 100, 1, 1, 1, ?, ?, ?)
                """, arguments: ["e\(i)", food.id, now, now, now])
            }
        }
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try DataPortability(f.db).exportJSON()
            _ = try DataPortability(f.db).exportCSV()
        }
        #expect(elapsed < .seconds(2))
    }

    // MARK: Hydration

    private func liquid(_ f: Fixture, _ name: String, fat: Double = 0, countsAsFluid: Bool? = nil) throws -> Food {
        var food = Food(name: name, per100: Nutrients(kcal: 50, proteinG: 3, carbsG: 5, fatG: fat), isLiquid: true)
        food.countsAsFluid = countsAsFluid
        return try f.foods.save(FoodDetail(food: food)).food
    }

    @Test func `export import keeps hydration columns`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let cola = try f.diary.log(food: liquid(f, "Cola"), quantity: .base(330), slotID: "snacks", day: d)
        // Switched off although liquid: an import must not apply the automatic rule again.
        let shake = try f.diary.log(food: liquid(f, "Shake", countsAsFluid: false), quantity: .base(300), slotID: "snacks", day: d)
        let espresso = try f.caffeine.add(mg: 64, day: d, drinkID: "espresso")
        let custom = try f.caffeine.add(mg: 80, day: d, ml: 200)
        var profile = try f.profiles.profile()
        profile.waterGoalMl = 3000 // a custom amount kept for later, while the goal follows the weight
        profile.waterGoalMode = .weight
        try f.profiles.save(profile)
        let woke = Date(timeIntervalSince1970: 1_794_288_600)
        try DailyMetricsRepository(f.db, clock: f.clock.appClock).upsert([DailyHealthMetrics(day: d, wokeAt: woke)])
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()

        let target = try Fixture()
        try DataPortability(target.db, clock: f.clock.appClock).importJSON(json, mode: .replace)
        #expect(try DataPortability(target.db, clock: f.clock.appClock).exportJSON() == json)
        #expect(try target.diary.entry(id: cola.id)?.fluidMl == 330)
        #expect(try target.diary.entry(id: shake.id)?.fluidMl == nil)
        #expect(try target.foods.food(id: #require(shake.foodID))?.countsAsFluid == false)
        #expect(try target.caffeine.entry(id: espresso.id)?.ml == 30)
        #expect(try target.caffeine.entry(id: custom.id)?.ml == 200)
        #expect(try target.profiles.profile().waterGoalMode == .weight)
        #expect(try target.profiles.profile().waterGoalMl == 3000)
        #expect(try DailyMetricsRepository(target.db).metrics(on: d)?.wokeAt == woke)
    }

    /// An export of `f` as an app before hydration tracking (schema 12) wrote it: without the hydration columns.
    private func preHydrationExport(_ f: Fixture) throws -> Data {
        let json = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var tables = try #require(object["tables"] as? [String: [[String: Any]]])
        let removed: [String: String] = [
            "diary_entry": "fluid_ml", "food": "counts_as_fluid", "caffeine_entry": "ml", "daily_metrics": "woke_at",
            "profile": "water_goal_mode",
        ]
        for (table, column) in removed {
            tables[table] = tables[table]?.map { $0.filter { $0.key != column } }
        }
        object["tables"] = tables
        object["schemaVersion"] = 12
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func `an export from before hydration gets the hydration backfills`() throws {
        let f = try Fixture()
        let d = day("2026-11-09")
        let milk = try f.diary.log(food: liquid(f, "Milk", fat: 3.5), quantity: .base(250), slotID: "breakfast", day: d)
        let bread = try f.diary.log(food: f.makeFood("Bread"), quantity: .base(50), slotID: "breakfast", day: d)
        f.clock.advance(60)
        let espresso = try f.caffeine.add(mg: 64, day: d, drinkID: "espresso", name: "Espresso")
        var profile = try f.profiles.profile()
        profile.waterGoalMl = 3000
        try f.profiles.save(profile)
        let old = try preHydrationExport(f)

        let target = try Fixture()
        try DataPortability(target.db, clock: f.clock.appClock).importJSON(old, mode: .replace)
        #expect(try target.profiles.profile().waterGoalMode == .fixed)
        #expect(try target.diary.entry(id: milk.id)?.fluidMl == 250)
        #expect(try target.diary.entry(id: bread.id)?.fluidMl == nil)
        #expect(try target.caffeine.entry(id: espresso.id)?.ml == 30)
        #expect(try HydrationRepository(target.db).intakes(in: d ... d)[d]?.map(\.ml) == [250, 30])

        // Merge: only the file's rows are repaired; newer local rows keep their hydration values.
        let local = try Fixture()
        local.clock.advance(3600)
        let shake = try local.diary.log(
            food: liquid(local, "Shake", countsAsFluid: false), quantity: .base(300), slotID: "snacks", day: d,
        )
        var localProfile = try local.profiles.profile()
        localProfile.waterGoalMl = 3000
        localProfile.waterGoalMode = .weight
        try local.profiles.save(localProfile)
        try DataPortability(local.db, clock: local.clock.appClock).importJSON(old, mode: .merge)
        #expect(try local.profiles.profile().waterGoalMode == .weight)
        #expect(try local.diary.entry(id: shake.id)?.fluidMl == nil)
        #expect(try local.diary.entry(id: milk.id)?.fluidMl == 250)
        #expect(try local.caffeine.entry(id: espresso.id)?.ml == 30)
    }

    @Test func `timestamps parse both formats`() {
        #expect(Timestamp.date("2026-11-09T14:03:12.345Z") != nil)
        #expect(Timestamp.date("2026-11-09T14:03:12Z") != nil)
        #expect(Timestamp.date("nope") == nil)
        let d = Date(timeIntervalSince1970: 1_794_200_000.5)
        #expect(Timestamp.string(d) == "2026-11-09T04:53:20.500Z")
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
