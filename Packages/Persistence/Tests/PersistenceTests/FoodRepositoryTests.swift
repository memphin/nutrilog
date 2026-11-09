import Core
import Foundation
import Testing
@testable import Persistence

struct FoodRepositoryTests {
    @Test func `creates food with servings and normalized barcodes`() throws {
        let f = try Fixture()
        let food = try f.makeFood(
            "Toast bread",
            servings: [Serving(label: "slice", grams: 25), Serving(label: "half loaf", grams: 250)],
            barcodes: ["036000291452", "4006381333931", "036000291452"],
        )
        let detail = try #require(try f.foods.detail(id: food.id))
        #expect(detail.servings.map(\.label) == ["slice", "half loaf"])
        #expect(detail.servings.map(\.sortOrder) == [0, 1])
        #expect(detail.barcodes == ["0036000291452", "4006381333931"]) // UPC-A stored as EAN-13, deduplicated
        #expect(detail.food.createdAt == f.clock.now)
        #expect(detail.food.revision == 1)
    }

    @Test func `lookup by barcode normalizes input`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Cola", barcodes: ["036000291452"])
        #expect(try f.foods.food(barcode: "0036000291452")?.food.id == food.id)
        #expect(try f.foods.food(barcode: "00036000291452")?.food.id == food.id) // GTIN-14
        #expect(try f.foods.food(barcode: "4006381333931") == nil)
        #expect(try f.foods.food(barcode: "garbage") == nil)
    }

    @Test func `ambiguous eight digit code is found whatever the scanner reports`() throws {
        let f = try Fixture()
        // 01000009 has a valid EAN-8 check digit and also expands to a valid UPC-E (0010000000009).
        #expect(Barcode.normalize("01000009") == "01000009")
        #expect(Barcode.normalize("01000009", symbology: .upcE) == "0010000000009")
        let food = try f.makeFood("Gum", barcodes: ["01000009"])
        #expect(try f.foods.food(barcode: "01000009", symbology: .upcE)?.food.id == food.id)
        #expect(try f.foods.food(barcode: "01000009", symbology: .ean8)?.food.id == food.id)
    }

    @Test func `hinted barcode reading wins and ean8 hint never falls back`() throws {
        let f = try Fixture()
        let upce = try f.makeFood("UPC-E product", barcodes: ["0010000000009"])
        #expect(try f.foods.food(barcode: "01000009", symbology: .ean8) == nil) // different code space
        #expect(try f.foods.food(barcode: "01000009", symbology: .upcE)?.food.id == upce.id)
        let ean8 = try f.makeFood("EAN-8 product", barcodes: ["01000009"])
        #expect(try f.foods.food(barcode: "01000009", symbology: .ean8)?.food.id == ean8.id)
        #expect(try f.foods.food(barcode: "01000009", symbology: .upcE)?.food.id == upce.id)
    }

    @Test func `invalid barcode is rejected`() throws {
        let f = try Fixture()
        #expect(throws: PersistenceError.invalidBarcode("4006381333932")) {
            try f.makeFood("Bad", barcodes: ["4006381333932"])
        }
    }

    @Test func `barcode owned by another active food is rejected but deleted owner releases it`() throws {
        let f = try Fixture()
        let first = try f.makeFood("First", barcodes: ["4006381333931"])
        #expect(throws: PersistenceError.barcodeInUse(barcode: "4006381333931", foodID: first.id)) {
            try f.makeFood("Second", barcodes: ["4006381333931"])
        }
        try f.foods.softDelete(id: first.id)
        let second = try f.makeFood("Second", barcodes: ["4006381333931"])
        #expect(try f.foods.food(barcode: "4006381333931")?.food.id == second.id)
    }

    @Test func `moving a barcode from an active food needs consent and unlinks it there`() throws {
        let f = try Fixture()
        let first = try f.makeFood("First", barcodes: ["4006381333931", "3850104003455"])
        let draft = FoodDetail(
            food: Food(name: "Second", per100: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0)),
            barcodes: ["4006381333931"],
        )
        // The editor asks first: the owner is reported (the food being edited is not its own conflict).
        let owners = try f.foods.activeOwners(of: ["4006381333931", "0036000291452"], excluding: draft.food.id)
        #expect(owners.map(\.barcode) == ["4006381333931"])
        #expect(owners.map(\.food.id) == [first.id])
        #expect(try f.foods.activeOwners(of: ["4006381333931"], excluding: first.id).isEmpty)
        // Without consent nothing changes.
        #expect(throws: PersistenceError.barcodeInUse(barcode: "4006381333931", foodID: first.id)) {
            try f.foods.save(draft)
        }
        #expect(try f.foods.food(barcode: "4006381333931")?.food.id == first.id)

        f.clock.advance(60)
        let second = try f.foods.save(draft, movingBarcodes: ["4006381333931"])
        #expect(try f.foods.food(barcode: "4006381333931")?.food.id == second.food.id)
        let previous = try #require(try f.foods.detail(id: first.id))
        #expect(previous.barcodes == ["3850104003455"])
        #expect(previous.food.revision == 2) // its barcodes changed
        #expect(previous.food.updatedAt == f.clock.now)
    }

    @Test func `removing a barcode unlinks it so a scan no longer finds the food`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Ajvar", barcodes: ["3850104003455", "4006381333931"])
        var detail = try #require(try f.foods.detail(id: food.id))
        detail.barcodes = ["4006381333931"]
        try f.foods.save(detail)
        #expect(try f.foods.food(barcode: "3850104003455") == nil)
        #expect(try f.foods.detail(id: food.id)?.barcodes == ["4006381333931"])
        let rows = try f.db.reader.read { db in try FoodBarcode.fetchCount(db) }
        #expect(rows == 1)
        // The freed code can go on another food without a conflict.
        let other = try f.makeFood("Other ajvar", barcodes: ["3850104003455"])
        #expect(try f.foods.food(barcode: "3850104003455")?.food.id == other.id)
    }

    @Test func `update bumps revision and timestamp and syncs servings`() throws {
        let f = try Fixture()
        let created = try f.foods.save(FoodDetail(
            food: Food(name: "Yogurt", per100: Nutrients(kcal: 60, proteinG: 4, carbsG: 5, fatG: 3)),
            servings: [Serving(label: "cup", grams: 150), Serving(label: "spoon", grams: 15)],
        ))
        f.clock.advance(60)
        var detail = created
        detail.food.name = "Greek yogurt"
        detail.food.defaultServingID = detail.servings[1].id
        detail.servings = [detail.servings[1]] // drop "cup", keep "spoon" (removed default stays valid)
        let updated = try f.foods.save(detail)
        #expect(updated.food.revision == 2)
        #expect(updated.food.updatedAt == f.clock.now)
        #expect(updated.food.createdAt == created.food.createdAt)

        let reloaded = try #require(try f.foods.detail(id: created.food.id))
        #expect(reloaded.food.name == "Greek yogurt")
        #expect(reloaded.servings.map(\.label) == ["spoon"])
        #expect(reloaded.food.defaultServingID == detail.servings[0].id)

        // Removing the default serving clears the default.
        var again = reloaded
        again.servings = []
        let cleared = try f.foods.save(again)
        #expect(cleared.food.defaultServingID == nil)
    }

    @Test func `soft delete hides food from default fetches`() throws {
        let f = try Fixture()
        let food = try f.makeFood("Ajvar", barcodes: ["3850104003455"])
        try f.foods.setFavorite(id: food.id, true)
        f.clock.advance(10)
        try f.foods.softDelete(id: food.id)
        try f.foods.softDelete(id: food.id) // idempotent
        let stored = try #require(try f.foods.food(id: food.id))
        #expect(stored.deletedAt == f.clock.now)
        #expect(stored.revision == 3) // create, favorite, delete
        #expect(try f.foods.favorites().isEmpty)
        #expect(try f.foods.food(barcode: "3850104003455") == nil)
        #expect(try f.foods.customFoods().isEmpty)
        #expect(throws: PersistenceError.notFound("missing")) { try f.foods.softDelete(id: "missing") }
    }

    @Test func favorites() throws {
        let f = try Fixture()
        let b = try f.makeFood("Banana")
        let a = try f.makeFood("apple")
        try f.makeFood("Cherry")
        try f.foods.setFavorite(id: b.id, true)
        try f.foods.setFavorite(id: a.id, true)
        try f.foods.setFavorite(id: a.id, true) // no-op
        #expect(try f.foods.favorites().map(\.name) == ["apple", "Banana"])
        try f.foods.setFavorite(id: b.id, false)
        #expect(try f.foods.favorites().map(\.name) == ["apple"])
        #expect(throws: PersistenceError.notFound("x")) { try f.foods.setFavorite(id: "x", true) }
    }

    @Test func `recents are slot aware and skip deleted foods`() throws {
        let f = try Fixture()
        let oats = try f.makeFood("Oats")
        let pizza = try f.makeFood("Pizza")
        let gone = try f.makeFood("Gone")
        let today = LocalDay(f.clock.now)
        for _ in 0 ..< 4 {
            try f.diary.log(food: oats, quantity: .base(50), slotID: "breakfast", day: today)
        }
        for _ in 0 ..< 3 {
            try f.diary.log(food: pizza, quantity: .base(300), slotID: "dinner", day: today)
        }
        try f.diary.log(food: gone, quantity: .base(10), slotID: "breakfast", day: today)
        try f.foods.softDelete(id: gone.id)

        #expect(try f.foods.recents(slotID: "breakfast").map(\.name) == ["Oats", "Pizza"])
        #expect(try f.foods.recents(slotID: "dinner").map(\.name) == ["Pizza", "Oats"])
        #expect(try f.foods.recents(slotID: nil, limit: 1).map(\.name) == ["Oats"])

        f.clock.advance(61 * 86400) // outside the 60-day window
        #expect(try f.foods.recents(slotID: "breakfast").isEmpty)
    }

    @Test func `local copy of bundled food is created once and revived`() throws {
        let f = try Fixture()
        let bundled = BundledFood(
            id: "b1",
            sourceID: "171705",
            name: "Bananas, raw",
            per100: Nutrients(kcal: 89, proteinG: 1.1, carbsG: 22.8, fatG: 0.3),
        )
        let first = try f.foods.localCopy(of: bundled)
        let second = try f.foods.localCopy(of: bundled)
        #expect(first.id == second.id)
        #expect(first.source == .bundled)
        #expect(first.sourceID == "171705")
        try f.foods.softDelete(id: first.id)
        let revived = try f.foods.localCopy(of: bundled)
        #expect(revived.id == first.id)
        #expect(revived.deletedAt == nil)
    }

    @Test func `suggested quantity`() {
        var food = Food(name: "Bread", per100: .zero)
        let slice = Serving(label: "slice", grams: 25)
        var detail = FoodDetail(food: food, servings: [slice])
        #expect(detail.suggestedQuantity == .base(100))
        food.defaultServingID = slice.id
        detail.food = food
        #expect(detail.suggestedQuantity == .servings(count: 1, serving: slice.size))
        detail.food.lastAmount = 60
        #expect(detail.suggestedQuantity == .base(60))
        detail.food.lastServingID = slice.id
        detail.food.lastAmount = 3
        #expect(detail.suggestedQuantity == .servings(count: 3, serving: slice.size))
    }

    @Test func `display name and base unit`() {
        var food = Food(name: "Milk", brand: "Dukat", per100: .zero, isLiquid: true)
        #expect(food.displayName == "Milk · Dukat")
        #expect(food.baseUnit == .milliliters)
        food.brand = ""
        #expect(food.displayName == "Milk")
    }
}
