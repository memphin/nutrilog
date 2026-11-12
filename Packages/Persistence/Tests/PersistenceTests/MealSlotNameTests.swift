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
        #expect(try croatian("Breakfast") == "Doručak")
        #expect(try croatian("Snacks") == "Međuobroci")
    }

    /// Xcode and Swift Build compile the catalog into `hr.lproj`; SwiftPM's native build system (used by
    /// `swift test` on CI) copies `Localizable.xcstrings` into the bundle as is, so read it directly there.
    private func croatian(_ key: String) throws -> String? {
        if let path = Bundle.module.path(forResource: "hr", ofType: "lproj") {
            let bundle = try #require(Bundle(path: path))
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"))
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: url))
        return catalog.strings[key]?.localizations?["hr"]?.stringUnit?.value
    }

    private struct StringCatalog: Decodable {
        struct Entry: Decodable { var localizations: [String: Localization]? }
        struct Localization: Decodable { var stringUnit: StringUnit? }
        struct StringUnit: Decodable { var value: String }
        var strings: [String: Entry]
    }
}
