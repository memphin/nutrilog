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
        #expect(!profile.isCompleteForFormula)
        profile.heightCm = 180
        profile.birthDate = day("1990-05-01")
        profile.sex = .male
        profile.activityLevel = .veryActive
        try f.profiles.save(profile)
        let saved = try f.profiles.profile()
        #expect(saved.isCompleteForFormula)
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
        #expect(try f.profiles.latestWeight() == nil)
        try f.profiles.addWeight(kg: 82.4, at: f.clock.now.addingTimeInterval(-86400))
        try f.profiles.addWeight(kg: 82.0, bodyFatPct: 18)
        #expect(try f.profiles.latestWeight()?.kg == 82.0)
        #expect(throws: PersistenceError.validation("weight out of range")) { try f.profiles.addWeight(kg: 0) }
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
        try f.profiles.addWeight(kg: 81.25, bodyFatPct: 17.5)
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-11-01"),
            kcal: 2100,
            macros: MacroTargets(proteinG: 150, carbsG: 210, fatG: 70),
            origin: .formula,
        ))
        try f.profiles.setSetting("showKJ", false)
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

    @Test func `timestamps parse both formats`() {
        #expect(Timestamp.date("2026-11-09T14:03:12.345Z") != nil)
        #expect(Timestamp.date("2026-11-09T14:03:12Z") != nil)
        #expect(Timestamp.date("nope") == nil)
        let d = Date(timeIntervalSince1970: 1_794_200_000.5)
        #expect(Timestamp.string(d) == "2026-11-09T04:53:20.500Z")
    }
}
