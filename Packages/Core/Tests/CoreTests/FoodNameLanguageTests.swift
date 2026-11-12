import Core
import Testing

/// Settings → Food names: which language built-in food names are shown in, and when a stored name may follow it.
struct FoodNameLanguageTests {
    @Test func `same as app follows the app language`() {
        #expect(FoodNamePreference.sameAsApp.resolved(appLanguage: .english) == .english)
        #expect(FoodNamePreference.sameAsApp.resolved(appLanguage: .croatian) == .croatian)
    }

    @Test func `a chosen language wins over the app language`() {
        #expect(FoodNamePreference.croatian.resolved(appLanguage: .english) == .croatian)
        #expect(FoodNamePreference.english.resolved(appLanguage: .croatian) == .english)
        #expect(FoodNamePreference.english.resolved(appLanguage: .english) == .english)
        #expect(FoodNamePreference.croatian.resolved(appLanguage: .croatian) == .croatian)
    }

    @Test func `default preference is same as app`() {
        #expect(FoodNamePreference.default == .sameAsApp)
    }

    @Test func `preference is stored by a stable raw value`() {
        #expect(FoodNamePreference.sameAsApp.rawValue == "sameAsApp")
        #expect(FoodNamePreference.english.rawValue == "en")
        #expect(FoodNamePreference.croatian.rawValue == "hr")
        #expect(FoodNamePreference(rawValue: "hr") == .croatian)
        #expect(FoodNamePreference(rawValue: "de") == nil)
    }

    @Test func `app language comes from the localization iOS picked`() {
        #expect(FoodNameLanguage(localization: "hr") == .croatian)
        #expect(FoodNameLanguage(localization: "hr-HR") == .croatian)
        #expect(FoodNameLanguage(localization: "hr_HR") == .croatian)
        #expect(FoodNameLanguage(localization: "en") == .english)
        #expect(FoodNameLanguage(localization: "en-GB") == .english)
        #expect(FoodNameLanguage(localization: "hry") == .english) // not Croatian, just starts with "hr"
        #expect(FoodNameLanguage(localization: nil) == .english)
    }
}

struct BilingualFoodNameTests {
    private static let en = "Fish, salmon, Atlantic, farmed, cooked, dry heat"
    private static let hr = "Losos, atlantski, uzgojeni, pečen"
    private let salmon = BilingualFoodName(english: en, croatian: hr)

    @Test func `name in each language`() {
        #expect(salmon.name(in: .english) == Self.en)
        #expect(salmon.name(in: .croatian) == Self.hr)
        #expect(salmon.otherName(than: .english) == Self.hr)
        #expect(salmon.otherName(than: .croatian) == Self.en)
    }

    @Test func `without a croatian name both languages show english`() {
        let banana = BilingualFoodName(english: "Bananas, raw", croatian: nil)
        #expect(banana.name(in: .croatian) == "Bananas, raw")
        #expect(banana.otherName(than: .croatian) == nil)
        #expect(banana.otherName(than: .english) == nil)
        let blank = BilingualFoodName(english: "Bananas, raw", croatian: "")
        #expect(blank.croatian == nil)
    }

    @Test func `the same word in both languages has no other name`() {
        let kiwi = BilingualFoodName(english: "Kiwi", croatian: "Kiwi")
        #expect(kiwi.name(in: .croatian) == "Kiwi")
        #expect(kiwi.otherName(than: .croatian) == nil)
        #expect(kiwi.otherName(than: .english) == nil)
    }

    @Test func `a copy with the english name switches to croatian`() throws {
        let renamed = try #require(salmon.switching(name: Self.en, nameLocal: Self.hr, to: .croatian))
        #expect(renamed.name == Self.hr)
        #expect(renamed.nameLocal == Self.en)
    }

    @Test func `a copy with the croatian name switches to english`() throws {
        let renamed = try #require(salmon.switching(name: Self.hr, nameLocal: Self.en, to: .english))
        #expect(renamed.name == Self.en)
        #expect(renamed.nameLocal == Self.hr)
    }

    @Test func `switching there and back restores the copy exactly`() throws {
        let croatian = try #require(salmon.switching(name: Self.en, nameLocal: Self.hr, to: .croatian))
        let back = try #require(salmon.switching(name: croatian.name, nameLocal: croatian.nameLocal, to: .english))
        #expect(back.name == Self.en)
        #expect(back.nameLocal == Self.hr)
    }

    @Test func `a copy already in the language is left alone`() {
        #expect(salmon.switching(name: Self.en, nameLocal: Self.hr, to: .english) == nil)
        #expect(salmon.switching(name: Self.hr, nameLocal: Self.en, to: .croatian) == nil)
    }

    @Test func `a copy in the language gets the other name as its local name`() throws {
        // E.g. a USDA copy saved with the English name only: the Croatian name is filled in so search finds it.
        let filled = try #require(salmon.switching(name: Self.en, nameLocal: nil, to: .english))
        #expect(filled.name == Self.en)
        #expect(filled.nameLocal == Self.hr)
    }

    @Test func `a copy the user renamed is left alone`() {
        #expect(salmon.switching(name: "Salmon fillet", nameLocal: Self.hr, to: .croatian) == nil)
        #expect(salmon.switching(name: "Salmon fillet", nameLocal: nil, to: .english) == nil)
        // Exact match only: case and spacing count.
        #expect(salmon.switching(name: "fish, salmon, atlantic, farmed, cooked, dry heat", nameLocal: nil, to: .croatian) == nil)
        #expect(salmon.switching(name: "Losos, atlantski, uzgojeni, pečen ", nameLocal: nil, to: .english) == nil)
    }

    @Test func `nothing switches without a croatian name`() {
        let banana = BilingualFoodName(english: "Bananas, raw", croatian: nil)
        #expect(banana.switching(name: "Bananas, raw", nameLocal: nil, to: .croatian) == nil)
        #expect(banana.switching(name: "Bananas, raw", nameLocal: "Banane", to: .english) == nil)
        #expect(banana.switchingSnapshot("Bananas, raw", to: .croatian) == nil)
    }

    @Test func `the same word in both languages keeps no local name`() {
        let kiwi = BilingualFoodName(english: "Kiwi", croatian: "Kiwi")
        #expect(kiwi.switching(name: "Kiwi", nameLocal: nil, to: .croatian) == nil)
        #expect(kiwi.switching(name: "Kiwi", nameLocal: nil, to: .english) == nil)
    }

    @Test func `a logged name switches when it is one of the two names`() {
        #expect(salmon.switchingSnapshot(Self.en, to: .croatian) == Self.hr)
        #expect(salmon.switchingSnapshot(Self.hr, to: .english) == Self.en)
        #expect(salmon.switchingSnapshot(Self.en, to: .english) == nil) // already right
        #expect(salmon.switchingSnapshot(Self.hr, to: .croatian) == nil)
        #expect(salmon.switchingSnapshot("Salmon fillet", to: .croatian) == nil) // the user's own name
    }
}
