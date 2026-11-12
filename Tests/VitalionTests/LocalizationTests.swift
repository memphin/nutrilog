import Foundation
import Testing

/// The Croatian translation (FR-74): the app ships it, and counts take Croatian's three plural forms (1 / 2–4 / 5+,
/// with 11–14 in the last). The test runner itself runs in English, so these read the `hr.lproj` bundle directly.
struct LocalizationTests {
    private let croatian = Locale(identifier: "hr_HR")

    private func croatianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "hr", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func `the app ships English and Croatian`() {
        #expect(Bundle.main.localizations.contains("en"))
        #expect(Bundle.main.localizations.contains("hr"))
    }

    @Test func `croatian counts use three plural forms`() throws {
        let bundle = try croatianBundle()
        func foods(_ count: Int) -> String {
            String(localized: "\(count) foods", bundle: bundle, locale: croatian)
        }
        #expect(foods(1) == "1 namirnica")
        #expect(foods(2) == "2 namirnice")
        #expect(foods(4) == "4 namirnice")
        #expect(foods(5) == "5 namirnica")
        #expect(foods(12) == "12 namirnica") // 11–14 take the "other" form
        #expect(foods(21) == "21 namirnica")
        #expect(foods(22) == "22 namirnice")

        func hours(_ count: Int) -> String {
            String(localized: "\(count) hours", bundle: bundle, locale: croatian)
        }
        #expect(hours(1) == "1 sat")
        #expect(hours(3) == "3 sata")
        #expect(hours(7) == "7 sati")
    }

    @Test func `croatian reorders arguments`() throws {
        let bundle = try croatianBundle()
        let count = 3
        let source = "USDA"
        #expect(String(localized: "\(count) results from \(source)", bundle: bundle, locale: croatian)
            == "USDA: 3 rezultata")
    }

    @Test func `english counts have a singular`() {
        let english = Locale(identifier: "en_US")
        let one = 1
        let two = 2
        #expect(String(localized: "\(one) foods", locale: english) == "1 food")
        #expect(String(localized: "\(two) foods", locale: english) == "2 foods")
    }

    @Test func `plain strings are translated`() throws {
        let bundle = try croatianBundle()
        #expect(String(localized: "Diary", bundle: bundle, locale: croatian) == "Dnevnik")
        #expect(String(localized: "Settings", bundle: bundle, locale: croatian) == "Postavke")
    }
}
