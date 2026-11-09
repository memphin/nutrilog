import Core
import Foundation

/// Maps an ``OFFProduct`` to a ``FoodDraft`` (SPEC §9 "Nutrient mapping notes").
///
/// - Energy: `energy-kcal_100g`, else kJ (`energy-kj_100g`, else `energy_100g`, which OFF always stores in kJ) ÷ 4.184.
/// - Sodium: `salt_100g` × 400 mg, else `sodium_100g` (g) × 1000.
/// - Each value prefers its `_100g` key; a `_serving` value is scaled to 100 g/ml when the serving weight is known
///   (`serving_quantity`, else parsed from `serving_size`).
/// - Products with per-serving values only and no serving weight keep per-serving values (`basis = .perServing`,
///   data quality partial).
/// - Negative and non-finite values count as missing.
public enum OFFFoodMapper {
    public static let kJPerKcal = 4.184

    public static func map(_ product: OFFProduct) -> FoodDraft {
        let isLiquid = isLiquid(product)
        let servingAmount = servingAmount(product)
        let servingDescription = clean(product.servingSize)

        let per100 = NutrientValues(product.nutriments, servingGrams: servingAmount)
        let perServing = NutrientValues(product.nutriments, servingOnly: true)
        let useServing = per100.isEmpty && !perServing.isEmpty
        let values = useServing ? perServing : per100

        let serving = servingAmount.map { amount in
            ServingSize(
                label: servingDescription ?? "\(NumberFormatting.compact(amount)) \(BaseUnit(isLiquid: isLiquid).symbol)",
                amount: amount,
            )
        }
        let names = names(product)
        let code = product.code

        return FoodDraft(
            origin: .off,
            sourceID: code,
            barcode: code.isEmpty ? nil : code,
            name: names.name,
            nameLocal: names.local,
            brand: firstBrand(product.brands),
            nutrients: values.nutrients,
            basis: useServing ? .perServing : .per100,
            missingNutrients: values.missing,
            isLiquid: isLiquid,
            serving: serving,
            servingDescription: servingDescription,
            packageDescription: clean(product.quantity),
            imageURL: httpURL(product.imageFrontSmallURL),
            nutriscore: nutriscore(product.nutriscoreGrade),
            productURL: code.isEmpty ? nil : URL(string: "https://world.openfoodfacts.org/product/\(code)"),
            ingredientsText: clean(product.ingredientsText),
            allergens: product.allergensTags,
            lastModified: product.lastModified,
        )
    }

    // MARK: - Names

    static func names(_ product: OFFProduct) -> (name: String?, local: String?) {
        let name = clean(product.productName) ?? clean(product.productNameEN) ?? clean(product.productNameHR)
            ?? clean(product.genericName)
        guard let croatian = clean(product.productNameHR),
              croatian.compare(name ?? "", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else {
            return (name, nil)
        }
        return (name, croatian)
    }

    static func firstBrand(_ brands: String?) -> String? {
        brands?.split(separator: ",").lazy.compactMap { clean(String($0)) }.first
    }

    // MARK: - Serving & liquid

    /// Serving weight in the base unit: `serving_quantity` when positive, else parsed from `serving_size`.
    static func servingAmount(_ product: OFFProduct) -> Double? {
        if let quantity = product.servingQuantity, quantity > 0, quantity.isFinite {
            return quantity
        }
        return product.servingSize.flatMap(MeasureParser.parse)?.amount
    }

    static func isLiquid(_ product: OFFProduct) -> Bool {
        for unit in [product.servingQuantityUnit, product.productQuantityUnit] {
            switch unit?.lowercased() {
            case "ml", "cl", "dl", "l": return true
            case "g", "kg", "mg": return false
            default: continue
            }
        }
        if let unit = product.quantity.flatMap(MeasureParser.parse)?.unit {
            return unit == .milliliters
        }
        return product.servingSize.flatMap(MeasureParser.parse)?.unit == .milliliters
    }

    // MARK: - Misc fields

    static func nutriscore(_ grade: String?) -> String? {
        guard let grade = clean(grade)?.lowercased(), ["a", "b", "c", "d", "e"].contains(grade) else { return nil }
        return grade
    }

    static func httpURL(_ text: String?) -> URL? {
        guard let text = clean(text), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else {
            return nil
        }
        return url
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Nutrient resolution

/// The mapped nutrient values of one basis (per 100 or per serving).
private struct NutrientValues {
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let satFat: Double?
    let sodiumMg: Double?

    /// Per-100 values: each `<key>_100g`, else `<key>_serving` × 100 / `servingGrams`.
    init(_ nutriments: [String: Double], servingGrams: Double?) {
        let scale = servingGrams.flatMap { $0 > 0 ? 100 / $0 : nil }
        self.init(nutriments) { key in
            if let value = Self.valid(nutriments["\(key)_100g"]) {
                return value
            }
            guard let scale, let value = Self.valid(nutriments["\(key)_serving"]) else { return nil }
            return value * scale
        }
    }

    /// Per-serving values: `<key>_serving` as given.
    init(_ nutriments: [String: Double], servingOnly _: Bool) {
        self.init(nutriments) { key in Self.valid(nutriments["\(key)_serving"]) }
    }

    private init(_: [String: Double], value: (String) -> Double?) {
        kcal = value("energy-kcal") ?? (value("energy-kj") ?? value("energy")).map { $0 / OFFFoodMapper.kJPerKcal }
        protein = value("proteins")
        carbs = value("carbohydrates")
        fat = value("fat")
        fiber = value("fiber")
        sugar = value("sugars")
        satFat = value("saturated-fat")
        sodiumMg = value("salt").map(Salt.sodiumMg(fromSaltG:)) ?? value("sodium").map { $0 * 1000 }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    var isEmpty: Bool {
        [kcal, protein, carbs, fat, fiber, sugar, satFat, sodiumMg].allSatisfy { $0 == nil }
    }

    var missing: Set<FoodDraft.MandatoryNutrient> {
        var missing: Set<FoodDraft.MandatoryNutrient> = []
        if kcal == nil {
            missing.insert(.energy)
        }
        if protein == nil {
            missing.insert(.protein)
        }
        if carbs == nil {
            missing.insert(.carbs)
        }
        if fat == nil {
            missing.insert(.fat)
        }
        return missing
    }

    var nutrients: Nutrients {
        Nutrients(
            kcal: kcal ?? 0,
            proteinG: protein ?? 0,
            carbsG: carbs ?? 0,
            fatG: fat ?? 0,
            fiberG: fiber,
            sugarG: sugar,
            satFatG: satFat,
            sodiumMg: sodiumMg,
        )
    }
}

// MARK: - Measure parsing

/// Reads an amount and unit from OFF text such as "30 g", "1 portion (30g)", "2 keksa (25 g)", "0,5 l", "33 cl",
/// "1 oz (28 g)". Metric units win over ounces; result is in grams or millilitres.
enum MeasureParser {
    static let gramsPerOunce = 28.349_523_125

    /// Factor to grams or millilitres per metric unit.
    private static let metricUnits: [String: (factor: Double, unit: BaseUnit)] = [
        "kg": (1000, .grams), "mg": (0.001, .grams),
        "g": (1, .grams), "gr": (1, .grams), "gram": (1, .grams), "grams": (1, .grams),
        "ml": (1, .milliliters), "cl": (10, .milliliters), "dl": (100, .milliliters), "l": (1000, .milliliters),
    ]

    static func parse(_ text: String) -> (amount: Double, unit: BaseUnit)? {
        let pattern = #/(?i)(\d+(?:[.,]\d+)?)\s*(kg|mg|grams|gram|gr|g|ml|cl|dl|l|oz)\b/#
        var ounces: Double?
        for match in text.matches(of: pattern) {
            guard let number = LenientNumber.parse(String(match.output.1)), number > 0 else { continue }
            if let metric = metricUnits[match.output.2.lowercased()] {
                return (number * metric.factor, metric.unit)
            }
            if ounces == nil {
                ounces = number * gramsPerOunce
            }
        }
        return ounces.map { ($0, .grams) }
    }
}
