import Core
import Foundation
import Testing
@testable import FoodSources

/// Mapper tests against fixture payloads. `nutella_complete`, `coca_cola_can` and `kras_dorina` are real OFF v2
/// responses (captured Nov 2026, trimmed to the fields allowlist); the others are hand-built in the same shape.
struct OFFFoodMapperTests {
    @Test func `real Nutella payload maps per 100 g and complete`() throws {
        let draft = try Fixture.draft("nutella_complete")
        #expect(draft.origin == .off)
        #expect(draft.sourceID == "3017620422003")
        #expect(draft.barcode == "3017620422003")
        #expect(draft.name == "Nutella")
        #expect(draft.nameLocal == nil)
        #expect(draft.brand == "Ferrero")
        #expect(draft.basis == .per100)
        #expect(draft.dataQuality == .complete)
        #expect(draft.missingNutrients.isEmpty)
        #expect(draft.nutrients.kcal == 539)
        #expect(draft.nutrients.proteinG == 6.3)
        #expect(draft.nutrients.carbsG == 57.5)
        #expect(draft.nutrients.fatG == 30.9)
        #expect(draft.nutrients.fiberG == 0)
        #expect(draft.nutrients.sugarG == 56.3)
        #expect(draft.nutrients.satFatG == 10.6)
        #expect(isClose(draft.nutrients.sodiumMg, 42.8)) // salt 0.107 g × 400
        #expect(draft.isLiquid == false)
        #expect(draft.serving == nil) // serving_quantity_unit without serving_quantity or serving_size
        #expect(draft.packageDescription == "400 g e")
        #expect(draft.nutriscore == "e")
        #expect(draft.imageURL?.host == "images.openfoodfacts.org")
        #expect(draft.productURL?.absoluteString == "https://world.openfoodfacts.org/product/3017620422003")
        #expect(draft.allergens == ["en:milk", "en:nuts", "en:soybeans"])
        #expect(draft.lastModified == Date(timeIntervalSince1970: 1_794_233_882))
    }

    @Test func `real Coca-Cola can payload is a liquid with a 330 ml serving`() throws {
        let draft = try Fixture.draft("coca_cola_can")
        #expect(draft.name == "Coca-Cola Original")
        #expect(draft.brand == "COCA-COLA SERVICES SA/NV")
        #expect(draft.dataQuality == .complete)
        #expect(draft.nutrients.kcal == 42.4)
        #expect(draft.nutrients.carbsG == 10.6)
        #expect(draft.nutrients.proteinG == 0)
        #expect(draft.nutrients.fatG == 0)
        #expect(draft.nutrients.sodiumMg == 0)
        #expect(draft.isLiquid)
        #expect(draft.baseUnit == .milliliters)
        #expect(draft.serving == ServingSize(label: "1 portion (330 ml)", amount: 330))
        #expect(draft.packageDescription == "330 ml")
    }

    @Test func `real Kraš Dorina payload maps complete`() throws {
        let draft = try Fixture.draft("kras_dorina")
        #expect(draft.sourceID == "3850102508648")
        #expect(draft.name == "Dorina")
        #expect(draft.brand == "Kras")
        #expect(draft.dataQuality == .complete)
        #expect(draft.nutrients.kcal == 536) // kJ 2202.3 is consistent, so kcal is kept
        #expect(draft.nutrients.proteinG == 5.7)
        #expect(draft.nutrients.carbsG == 50.5)
        #expect(draft.nutrients.fatG == 33.7)
        #expect(isClose(draft.nutrients.sodiumMg, 16)) // salt 0.04 g
        #expect(draft.nutriscore == nil) // "unknown"
        #expect(draft.serving == nil)
        #expect(draft.allergens.isEmpty)
    }

    @Test func `a Podravka product with English main name gets the Croatian name as local name`() throws {
        let draft = try Fixture.draft("podravka_vegeta_hr")
        #expect(draft.name == "Vegeta food seasoning with vegetables")
        #expect(draft.nameLocal == "Vegeta dodatak jelima s povrćem")
        #expect(draft.brand == "Podravka")
        #expect(isClose(draft.nutrients.sodiumMg, 22400)) // salt 56 g × 400 wins over sodium_100g 22.4 g
        #expect(draft.serving == ServingSize(label: "5 g", amount: 5)) // parsed from serving_size
        #expect(draft.nutriscore == nil) // "not-applicable"
        #expect(draft.dataQuality == .complete)
    }

    @Test func `kJ-only product converts energy to kcal`() throws {
        let draft = try Fixture.draft("kj_only")
        let expectedKcal = 1490 / 4.184
        #expect(isClose(draft.nutrients.kcal, expectedKcal))
        #expect(draft.dataQuality == .complete)
        #expect(draft.missingNutrients.isEmpty)
        #expect(draft.nutrients.proteinG == 9)
        #expect(isClose(draft.nutrients.sodiumMg, 440))
        #expect(draft.serving == ServingSize(label: "1 Scheibe (10 g)", amount: 10))
    }

    @Test func `energy_100g alone is read as kJ`() throws {
        let draft = try Fixture.draft("energy_legacy_only")
        #expect(isClose(draft.nutrients.kcal, 250))
        #expect(draft.dataQuality == .complete)
        #expect(draft.serving == nil)
        #expect(draft.nutrients.sodiumMg == nil)
    }

    @Test func `per-serving-only product with a serving weight is scaled to 100 g`() throws {
        let draft = try Fixture.draft("per_serving_only_with_quantity")
        #expect(draft.basis == .per100)
        #expect(draft.dataQuality == .complete)
        #expect(isClose(draft.nutrients.kcal, 360))
        #expect(isClose(draft.nutrients.proteinG, 33.333))
        #expect(isClose(draft.nutrients.carbsG, 30))
        #expect(isClose(draft.nutrients.fatG, 12))
        #expect(isClose(draft.nutrients.fiberG, 10))
        #expect(isClose(draft.nutrients.sugarG, 3))
        #expect(isClose(draft.nutrients.satFatG, 6.833))
        #expect(isClose(draft.nutrients.sodiumMg, 200)) // 0.3 g salt per 60 g → 0.5 g per 100 g
        #expect(draft.serving == ServingSize(label: "1 bar (60 g)", amount: 60))
    }

    @Test func `per-serving-only product without a serving weight stays per serving and partial`() throws {
        let draft = try Fixture.draft("per_serving_only_unknown_quantity")
        #expect(draft.basis == .perServing)
        #expect(draft.dataQuality == .partialMacros)
        #expect(draft.missingNutrients.isEmpty)
        #expect(draft.nutrients.kcal == 12)
        #expect(draft.nutrients.carbsG == 2.7)
        #expect(draft.serving == nil)
        #expect(draft.servingDescription == "1 shot")
        #expect(draft.isLiquid) // quantity "60 ml"
    }

    @Test func `serving weight parsed from a Croatian serving_size string scales per-serving values`() throws {
        let draft = try Fixture.draft("kras_domacica_serving_string")
        #expect(draft.name == "Domaćica keksi s mliječnom čokoladom")
        #expect(draft.basis == .per100)
        #expect(draft.dataQuality == .complete)
        #expect(draft.serving == ServingSize(label: "2 keksa (25 g)", amount: 25))
        #expect(isClose(draft.nutrients.kcal, 496))
        #expect(isClose(draft.nutrients.proteinG, 6.4))
        #expect(isClose(draft.nutrients.carbsG, 62))
        #expect(isClose(draft.nutrients.fatG, 24.4))
        #expect(isClose(draft.nutrients.sodiumMg, 128)) // "0,08" g salt per 25 g
    }

    @Test func `missing carbs make the food partial, sodium comes from sodium_100g without salt`() throws {
        let draft = try Fixture.draft("missing_macros")
        #expect(draft.missingNutrients == [.carbs])
        #expect(draft.dataQuality == .partialMacros)
        #expect(draft.nutrients.carbsG == 0)
        #expect(draft.nutrients.kcal == 356)
        #expect(isClose(draft.nutrients.sodiumMg, 320))
    }

    @Test func `energy without any macro is energy-only`() throws {
        let draft = try Fixture.draft("energy_only")
        #expect(draft.missingNutrients == [.protein, .carbs, .fat])
        #expect(draft.dataQuality == .energyOnly)
        #expect(draft.nutrients.kcal == 410)
    }

    @Test func `string-typed numbers are parsed, liquids detected`() throws {
        let draft = try Fixture.draft("string_numbers")
        #expect(draft.sourceID == "5449000000996") // code sent as a JSON number
        #expect(draft.nutrients.kcal == 42)
        #expect(draft.nutrients.carbsG == 10.6) // "10,6"
        #expect(draft.nutrients.sugarG == 10.6) // "10.6 g"
        #expect(draft.nutrients.proteinG == 0)
        #expect(draft.nutrients.fatG == 0)
        #expect(draft.nutrients.satFatG == nil) // ""
        #expect(isClose(draft.nutrients.sodiumMg, 4)) // "< 0.01"
        #expect(draft.dataQuality == .complete)
        #expect(draft.isLiquid)
        #expect(draft.baseUnit == .milliliters)
        #expect(draft.serving == ServingSize(label: "250 ml", amount: 250))
        #expect(draft.nutriscore == "e")
        #expect(draft.lastModified == Date(timeIntervalSince1970: 1_731_600_000))
    }

    @Test func `malformed values never crash and count as missing`() throws {
        let draft = try Fixture.draft("malformed_values")
        #expect(draft.name == "12345")
        #expect(draft.brand == nil)
        let expectedKcal = 1000 / 4.184
        #expect(isClose(draft.nutrients.kcal, expectedKcal)) // "abc" kcal ignored, kJ used
        #expect(draft.missingNutrients == [.protein, .carbs, .fat]) // -5, true, {…}
        #expect(draft.dataQuality == .energyOnly)
        #expect(draft.nutrients.fiberG == nil)
        #expect(draft.nutrients.sugarG == nil)
        #expect(draft.nutrients.sodiumMg == nil) // "NaN"
        #expect(draft.serving == nil)
        #expect(draft.servingDescription == "30")
        #expect(draft.imageURL == nil) // not http(s)
        #expect(draft.nutriscore == nil) // "unknown"
        #expect(draft.allergens.isEmpty) // a string instead of an array
        #expect(draft.lastModified == nil)
    }

    @Test func `product without nutrition is partial with everything missing`() throws {
        let draft = try Fixture.draft("no_nutrition")
        #expect(draft.name == "Kaugummi") // blank product_name falls back to generic_name
        #expect(draft.basis == .per100)
        #expect(draft.missingNutrients == Set(FoodDraft.MandatoryNutrient.allCases))
        #expect(draft.dataQuality == .partialMacros)
        #expect(draft.nutrients == .zero)
        #expect(draft.isLiquid == false)
    }

    @Test func `status 0 payload parses as not found`() throws {
        let response = try #require(OFFProductResponse.parse(Fixture.data("status0_not_found")))
        #expect(response.status == 0)
        #expect(response.product == nil)
    }

    @Test func `OFFProduct survives an encode-decode round trip for caching`() throws {
        for name in ["nutella_complete", "coca_cola_can", "string_numbers", "malformed_values", "no_nutrition"] {
            let product = try Fixture.product(name)
            let decoded = try JSONDecoder().decode(OFFProduct.self, from: JSONEncoder().encode(product))
            #expect(decoded == product, "\(name)")
        }
    }

    @Test func `a FoodDraft survives an encode-decode round trip`() throws {
        let draft = try Fixture.draft("per_serving_only_unknown_quantity")
        let decoded = try JSONDecoder().decode(FoodDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded == draft)
        #expect(decoded.dataQuality == .partialMacros)
    }

    @Test func `data quality raw values match the persistence model`() {
        #expect(FoodDataQuality.complete.rawValue == "complete")
        #expect(FoodDataQuality.partialMacros.rawValue == "partial_macros")
        #expect(FoodDataQuality.energyOnly.rawValue == "energy_only")
        #expect(FoodDraft.Origin.off.rawValue == "off")
    }

    private static let classificationCases: [(FoodDraft.NutrientBasis, Set<FoodDraft.MandatoryNutrient>, FoodDataQuality)] = [
        (.per100, [], .complete),
        (.per100, [.fat], .partialMacros),
        (.per100, [.energy], .partialMacros),
        (.per100, [.protein, .carbs, .fat], .energyOnly),
        (.per100, Set(FoodDraft.MandatoryNutrient.allCases), .partialMacros),
        (.perServing, [], .partialMacros),
    ]

    @Test func `data quality classification`() {
        for (basis, missing, expected) in Self.classificationCases {
            #expect(FoodDraft.classify(basis: basis, missing: missing) == expected, "\(basis) \(missing)")
        }
    }
}

struct LenientParsingTests {
    @Test(arguments: [
        ("12.5", 12.5),
        ("12,5", 12.5),
        (" 7 ", 7.0),
        ("< 0.5", 0.5),
        ("~3", 3.0),
        ("12 g", 12.0),
        ("0.", 0.0),
        ("-2", -2.0),
        ("4e-05", 0.00004),
        ("1.5E+2", 150.0),
        ("1.234,5", 1234.5),
        ("1,234.5", 1234.5),
        ("< 1,5e-3", 0.0015),
    ])
    func `numbers in strings`(text: String, expected: Double) {
        #expect(LenientNumber.parse(text) == expected)
    }

    @Test(arguments: ["", "abc", "NaN", "inf", "-", ".", "g 12", "1e400"])
    func `non-numbers are nil`(text: String) {
        #expect(LenientNumber.parse(text) == nil)
    }

    private static let measureCases: [(String, Double, BaseUnit)] = [
        ("30 g", 30, .grams),
        ("1 portion (30g)", 30, .grams),
        ("2 keksa (25 g)", 25, .grams),
        ("0,5 l", 500, .milliliters),
        ("33 cl", 330, .milliliters),
        ("2 dl", 200, .milliliters),
        ("250ml", 250, .milliliters),
        ("1 kg", 1000, .grams),
        ("500 mg", 0.5, .grams),
        ("100 gr", 100, .grams),
        ("1 oz (28 g)", 28, .grams),
    ]

    @Test func `measures`() throws {
        for (text, amount, unit) in Self.measureCases {
            let parsed = try #require(MeasureParser.parse(text), "\(text)")
            #expect(isClose(parsed.amount, amount, tolerance: 0.001), "\(text)")
            #expect(parsed.unit == unit, "\(text)")
        }
    }

    @Test func `ounces only when there is no metric unit`() throws {
        let parsed = try #require(MeasureParser.parse("1 oz"))
        #expect(isClose(parsed.amount, 28.35))
        #expect(parsed.unit == .grams)
    }

    @Test(arguments: ["1 shot", "1 large egg", "2 glasses", "", "30"])
    func `text without a unit has no measure`(text: String) {
        #expect(MeasureParser.parse(text) == nil)
    }
}
