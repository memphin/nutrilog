import Foundation
import Testing
@testable import Persistence

/// Seed meal slots are stored in English and shown in the app language until the user renames them (FR-74).
struct MealSlotNameTests {
    @Test func `seed slots show their name in the app language`() {
        let breakfast = MealSlot(id: "breakfast", name: "Breakfast", sortOrder: 0)
        #expect(breakfast.hasSeedName)
        // Tests run in English: the shown name equals the stored one.
        #expect(breakfast.displayName == "Breakfast")
    }

    @Test func `renamed and custom slots show as typed`() {
        let renamed = MealSlot(id: "breakfast", name: "Doručak", sortOrder: 0)
        #expect(!renamed.hasSeedName)
        #expect(renamed.displayName == "Doručak")
        let custom = MealSlot(name: "Breakfast", sortOrder: 4) // a new id: the user's own slot
        #expect(!custom.hasSeedName)
        #expect(custom.displayName == "Breakfast")
    }

    @Test func `croatian seed names are in the catalog`() throws {
        let path = try #require(Bundle.module.path(forResource: "hr", ofType: "lproj"))
        let croatian = try #require(Bundle(path: path))
        #expect(String(localized: "Breakfast", bundle: croatian, comment: "Meal slot") == "Doručak")
        #expect(String(localized: "Snacks", bundle: croatian, comment: "Meal slot") == "Međuobroci")
    }
}
