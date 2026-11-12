import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Settings → Food names (FR-74): the bundled index shows names in the chosen language, and copies of bundled foods,
/// their diary entries and planned entries switch with it unless the user renamed them.
struct FoodNameLanguageSwitchTests {
    private static let salmonEN = "Fish, salmon, Atlantic, farmed, cooked, dry heat"
    private static let salmonHR = "Losos, atlantski, uzgojeni, pečen"
    private static let riceEN = "Rice, brown, long-grain, cooked"
    private static let riceHR = "Riža, smeđa, dugozrnata, kuhana"

    private let rows: [(id: String, fdc: String, name: String, nameHR: String?)] = [
        ("b1", "175168", salmonEN, salmonHR),
        ("b2", "169704", riceEN, riceHR),
        ("b4", "173944", "Bananas, raw", nil),
    ]

    private func index() throws -> BundledFoodIndex {
        try BundledFoodIndex(url: makeBilingualIndexFile(rows: rows))
    }

    private var plans: (Fixture) -> MealPlanRepository {
        { MealPlanRepository($0.db, clock: $0.clock.appClock) }
    }

    // MARK: Index

    @Test func `index shows the names in the language asked for`() throws {
        let index = try index()
        #expect(try index.search("salmon", limit: 5, language: .croatian).map(\.name) == [Self.salmonHR])
        #expect(try index.search("losos", limit: 5, language: .english).map(\.name) == [Self.salmonEN])
        #expect(try index.food(id: "b2", language: .croatian)?.name == Self.riceHR)
        #expect(try index.food(id: "b2", language: .english)?.name == Self.riceEN)
        // The same index answers in either language, call by call.
        #expect(try index.food(id: "b1", language: .croatian)?.names == [Self.salmonHR, Self.salmonEN])
        #expect(try index.food(id: "b1", language: .english)?.names == [Self.salmonEN, Self.salmonHR])
    }

    @Test func `unified search shows bundled names in its language`() throws {
        let f = try Fixture()
        let index = try index()
        #expect(try FoodSearch(f.db, bundled: index, nameLanguage: .croatian).search("salmon").map(\.name) == [Self.salmonHR])
        #expect(try FoodSearch(f.db, bundled: index, nameLanguage: .english).search("losos").map(\.name) == [Self.salmonEN])
    }

    @Test func `index lists both names by FDC id`() throws {
        let names = try index().bilingualNames()
        #expect(names["175168"] == BilingualFoodName(english: Self.salmonEN, croatian: Self.salmonHR))
        #expect(names["173944"] == BilingualFoodName(english: "Bananas, raw", croatian: nil))
        #expect(names.count == 3)
        // An index built before the Croatian names has English only.
        let old = try makeBundledIndex(rows: [("b1", "171705", "Bananas, raw", 89)])
        #expect(try old.bilingualNames() == ["171705": BilingualFoodName(english: "Bananas, raw", croatian: nil)])
    }

    // MARK: Copies

    @Test func `copies of bundled foods switch language and back`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        let rice = try f.foods.localCopy(of: #require(try index.food(id: "b2", language: .croatian)))
        #expect(salmon.name == Self.salmonEN)
        #expect(rice.name == Self.riceHR)

        f.clock.advance(60)
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 1) // rice is Croatian already
        let salmonHR = try #require(try f.foods.food(id: salmon.id))
        #expect(salmonHR.name == Self.salmonHR)
        #expect(salmonHR.nameLocal == Self.salmonEN)
        #expect(salmonHR.revision == salmon.revision + 1)
        #expect(salmonHR.updatedAt == f.clock.now)
        #expect(try f.foods.food(id: rice.id) == rice) // untouched: same revision and updated_at

        #expect(try f.foods.applyBundledNames(.english, from: index) == 2)
        let salmonBack = try #require(try f.foods.food(id: salmon.id))
        #expect(salmonBack.name == salmon.name)
        #expect(salmonBack.nameLocal == salmon.nameLocal)
        let riceEN = try #require(try f.foods.food(id: rice.id))
        #expect(riceEN.name == Self.riceEN)
        #expect(riceEN.nameLocal == Self.riceHR)

        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 2)
        let riceBack = try #require(try f.foods.food(id: rice.id))
        #expect(riceBack.name == rice.name)
        #expect(riceBack.nameLocal == rice.nameLocal)
    }

    @Test func `switching by the stored choice reads it when it writes`() throws {
        let f = try Fixture()
        let index = try index()
        let copy = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        // Nothing stored: Same as app.
        let none = try f.foods.applyBundledNames(from: index, preferenceKey: "foodNames", appLanguage: .english)
        #expect(none.language == .english && none.changes == 0)
        // The stored choice wins over the app language.
        try f.profiles.setSetting("foodNames", FoodNamePreference.croatian.rawValue)
        let croatian = try f.foods.applyBundledNames(from: index, preferenceKey: "foodNames", appLanguage: .english)
        #expect(croatian.language == .croatian && croatian.changes == 1)
        #expect(try f.foods.food(id: copy.id)?.name == Self.salmonHR)
        // An unknown value counts as Same as app.
        try f.profiles.setSetting("foodNames", "klingon")
        let unknown = try f.foods.applyBundledNames(from: index, preferenceKey: "foodNames", appLanguage: .english)
        #expect(unknown.language == .english && unknown.changes == 1)
        #expect(try f.foods.food(id: copy.id)?.name == Self.salmonEN)
    }

    @Test func `switching is idempotent`() throws {
        let f = try Fixture()
        let index = try index()
        _ = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 1)
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 0)
        #expect(try f.foods.applyBundledNames(.english, from: index) == 1)
        #expect(try f.foods.applyBundledNames(.english, from: index) == 0)
    }

    @Test func `a renamed copy keeps its name`() throws {
        let f = try Fixture()
        let index = try index()
        var salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        salmon.name = "Salmon fillet"
        let saved = try f.foods.save(FoodDetail(food: salmon)).food
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 0)
        #expect(try f.foods.food(id: salmon.id) == saved)
    }

    @Test func `the new name is found by search in both languages`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        try f.foods.applyBundledNames(.croatian, from: index)
        let search = FoodSearch(f.db, bundled: index, nameLanguage: .croatian)
        #expect(try search.search("losos").map(\.id) == ["food:\(salmon.id)"])
        #expect(try search.search("salmon").map(\.id) == ["food:\(salmon.id)"])
        #expect(try search.search("salmon").map(\.name) == [Self.salmonHR])
    }

    @Test func `a copy without a croatian name stays as it is`() throws {
        let f = try Fixture()
        let index = try index()
        let banana = try f.foods.localCopy(of: #require(try index.food(id: "b4", language: .croatian)))
        #expect(banana.name == "Bananas, raw")
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 0)
        #expect(try f.foods.food(id: banana.id) == banana)
    }

    @Test func `a USDA copy of the same FDC id switches only with the exact bundled name`() throws {
        let f = try Fixture()
        let index = try index()
        let exact = try f.foods.save(FoodDetail(food: Food(
            name: Self.riceEN, source: .usda, sourceID: "169704", per100: Nutrients(kcal: 112, proteinG: 2.3, carbsG: 23.5, fatG: 0.8),
        ))).food
        let usdaStyled = try f.foods.save(FoodDetail(food: Food(
            name: "Fish, Salmon, Atlantic, Farmed, Cooked, Dry Heat", source: .usda, sourceID: "175168",
            per100: Nutrients(kcal: 206, proteinG: 22, carbsG: 0, fatG: 12),
        ))).food
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 1)
        let switched = try #require(try f.foods.food(id: exact.id))
        #expect(switched.name == Self.riceHR)
        #expect(switched.nameLocal == Self.riceEN)
        #expect(try f.foods.food(id: usdaStyled.id) == usdaStyled)

        // Back in English the name is restored; the Croatian name stays as the local name, so search still finds it.
        try f.foods.applyBundledNames(.english, from: index)
        let back = try #require(try f.foods.food(id: exact.id))
        #expect(back.name == Self.riceEN)
        #expect(back.nameLocal == Self.riceHR)
    }

    @Test func `own foods with a bundled name are never touched`() throws {
        let f = try Fixture()
        let index = try index()
        let own = try f.makeFood(Self.salmonEN)
        let offFood = try f.foods.save(FoodDetail(food: Food(
            name: Self.riceEN, source: .off, sourceID: "169704", per100: Nutrients(kcal: 1, proteinG: 1, carbsG: 1, fatG: 1),
        ))).food
        _ = try f.diary.log(food: own, quantity: .base(100), slotID: "lunch", day: day("2026-11-08"))
        let logged = try #require(try f.foods.food(id: own.id)) // logging counted a use
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 0)
        #expect(try f.foods.food(id: own.id) == logged)
        #expect(try f.foods.food(id: offFood.id) == offFood)
        #expect(try f.diary.diary(for: day("2026-11-08")).sections.flatMap(\.entries).map(\.displayName) == [Self.salmonEN])
    }

    @Test func `a deleted copy switches too, so reviving it shows the chosen language`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        try f.foods.softDelete(id: salmon.id)
        try f.foods.applyBundledNames(.croatian, from: index)
        let revived = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .croatian)))
        #expect(revived.id == salmon.id)
        #expect(revived.name == Self.salmonHR)
    }

    // MARK: Logged entries

    @Test func `past diary entries and planned entries switch and switch back`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        let logged = try f.diary.log(food: salmon, quantity: .base(150), slotID: "dinner", day: day("2026-11-01"))
        let planned = try plans(f).plan(food: salmon, quantity: .base(150), slotID: "dinner", day: day("2026-11-10"))
        let quick = try f.diary.logQuickAdd(
            name: Self.salmonEN, nutrients: Nutrients(kcal: 300, proteinG: 30, carbsG: 0, fatG: 18), slotID: "lunch",
            day: day("2026-11-01"),
        )

        f.clock.advance(60)
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 3) // the food, the entry, the plan
        let entryHR = try #require(try f.diary.entry(id: logged.id))
        #expect(entryHR.displayName == Self.salmonHR)
        #expect(entryHR.revision == logged.revision + 1)
        #expect(entryHR.updatedAt == f.clock.now)
        #expect(entryHR.kcal == logged.kcal) // only the name changes
        let plannedHR = try #require(try plans(f).entry(id: planned.id))
        #expect(plannedHR.displayName == Self.salmonHR)
        #expect(plannedHR.revision == planned.revision + 1)
        // A quick add has no food: its name is the user's, whatever it says.
        #expect(try f.diary.entry(id: quick.id)?.displayName == Self.salmonEN)

        #expect(try f.foods.applyBundledNames(.english, from: index) == 3)
        #expect(try f.diary.entry(id: logged.id)?.displayName == logged.displayName)
        #expect(try plans(f).entry(id: planned.id)?.displayName == planned.displayName)
    }

    @Test func `an entry the user renamed keeps its name even when the food switches`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        let logged = try f.diary.log(food: salmon, quantity: .base(150), slotID: "dinner", day: day("2026-11-01"))
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE diary_entry SET display_name = 'Mum''s salmon' WHERE id = ?", arguments: [logged.id])
        }
        try f.foods.applyBundledNames(.croatian, from: index)
        #expect(try f.diary.entry(id: logged.id)?.displayName == "Mum's salmon")
        #expect(try f.foods.food(id: salmon.id)?.name == Self.salmonHR)
    }

    @Test func `an entry of a renamed copy still switches while it carries a bundled name`() throws {
        let f = try Fixture()
        let index = try index()
        var salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        let logged = try f.diary.log(food: salmon, quantity: .base(150), slotID: "dinner", day: day("2026-11-01"))
        salmon.name = "Salmon fillet"
        try f.foods.save(FoodDetail(food: salmon))
        try f.foods.applyBundledNames(.croatian, from: index)
        #expect(try f.diary.entry(id: logged.id)?.displayName == Self.salmonHR)
        #expect(try f.foods.food(id: salmon.id)?.name == "Salmon fillet")
    }

    @Test func `switching queues no Apple Health write`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        _ = try f.diary.log(food: salmon, quantity: .base(150), slotID: "dinner", day: day("2026-11-01"))
        let before = try f.healthLinks.pending()
        try f.foods.applyBundledNames(.croatian, from: index)
        #expect(try f.healthLinks.pending() == before)
    }

    @Test func `saved meals show the switched food name`() throws {
        let f = try Fixture()
        let index = try index()
        let salmon = try f.foods.localCopy(of: #require(try index.food(id: "b1", language: .english)))
        let meals = MealTemplateRepository(f.db, clock: f.clock.appClock)
        let meal = try meals.create(name: "Fish dinner", items: [.init(foodID: salmon.id, grams: 150)])
        try f.foods.applyBundledNames(.croatian, from: index)
        #expect(try meals.detail(id: meal.template.id)?.items.map(\.food.name) == [Self.salmonHR])
    }

    @Test func `the real index switches a logged food`() throws {
        // The committed index — skipped when run outside the repo.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FoodIndex/bundled_foods.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let index = try BundledFoodIndex(url: url)
        let names = try index.bilingualNames()
        #expect(names.count >= 300)
        #expect(names.values.allSatisfy { $0.croatian != nil })

        let f = try Fixture()
        let hit = try #require(try index.search("salmon", limit: 1, language: .english).first)
        let copy = try f.foods.localCopy(of: hit)
        _ = try f.diary.log(food: copy, quantity: .base(100), slotID: "dinner", day: day("2026-11-01"))
        #expect(try f.foods.applyBundledNames(.croatian, from: index) == 2)
        #expect(try f.foods.food(id: copy.id)?.name == hit.croatianName)
        #expect(try f.diary.diary(for: day("2026-11-01")).sections.flatMap(\.entries).map(\.displayName) == [hit.croatianName])
    }
}
