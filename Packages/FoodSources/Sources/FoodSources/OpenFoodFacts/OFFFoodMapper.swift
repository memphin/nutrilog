import Core
import Foundation

/// Maps an ``OFFProduct`` to a ``FoodDraft`` (SPEC §9 "Nutrient mapping notes").
///
/// - Energy: `energy-kcal_100g`, else kJ (`energy-kj_100g`, else `energy_100g`, which OFF always stores in kJ) ÷ 4.184.
/// - Sodium: `salt_100g` × 400 mg, else `sodium_100g` (g) × 1000.
/// - Each value prefers its `_100g` key; a `_serving` value is scaled to 100 g/ml when the serving weight is known
///   (`serving_quantity`, else parsed from `serving_size`).
/// - When per-100 and per-serving values are both usable, the basis that leaves fewer mandatory nutrients missing
///   wins (ties go to per 100). Per-serving values without a usable serving weight stay per serving
///   (`basis = .perServing`, data quality partial).
/// - Negative, non-finite and physically impossible values count as missing (see ``NutrientValues``), so a
///   product with a typo is never classified complete.
public enum OFFFoodMapper {
    public static let kJPerKcal = 4.184
    /// Servings lighter than this (g/ml) are not scaled to 100 g: a rounded "10 kcal" on "1 tablet (500 mg)"
    /// would become 2000 kcal/100 g.
    public static let minimumScalableServing = 1.0
    /// Servings heavier than this (g/ml) are garbage ("serving_quantity": 1e19) and count as no serving at all.
    public static let maximumServing = 100_000.0

    /// `amount` when it is a usable serving weight (finite, above 0, at most ``maximumServing``), else `nil`.
    static func usableServing(_ amount: Double?) -> Double? {
        guard let amount, amount > 0, amount <= maximumServing else { return nil }
        return amount
    }

    public static func map(_ product: OFFProduct) -> FoodDraft {
        let isLiquid = isLiquid(product)
        let servingAmount = servingAmount(product)
        let servingDescription = clean(product.servingSize)

        let scalableServing = servingAmount.flatMap { $0 >= minimumScalableServing ? $0 : nil }
        let per100 = NutrientValues(per100From: product.nutriments, servingAmount: scalableServing).plausiblePer100()
        let perServing = NutrientValues(perServingFrom: product.nutriments)
        let useServing = !perServing.isEmpty
            && (per100.isEmpty || perServing.missing.count < per100.missing.count)
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

    /// Serving amount in g or ml: `serving_quantity` when positive and its unit is absent, g or ml; converted when
    /// its unit is another known one (kg, cl, oz, …); else parsed from `serving_size`.
    ///
    /// A serving in ml on a food measured in g (or the other way round) is used as is: like the rest of the app we
    /// accept a density of ≈ 1.
    ///
    /// Amounts that aren't finite, above 0 and at most ``maximumServing`` count as missing at each step.
    static func servingAmount(_ product: OFFProduct) -> Double? {
        if let quantity = usableServing(product.servingQuantity) {
            guard let unit = product.servingQuantityUnit?.lowercased(), unit != "g", unit != "ml" else {
                return quantity
            }
            if let converted = usableServing(MeasureParser.convert(quantity, unit: unit)?.amount) {
                return converted
            }
        }
        return usableServing(product.servingSize.flatMap(MeasureParser.parse)?.amount)
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

/// OFF `nutriments` keys → ``NutrientValues``.
extension NutrientValues {
    /// Per-100 values: each `<key>_100g`, else `<key>_serving` × 100 / `servingAmount`.
    init(per100From nutriments: [String: Double], servingAmount: Double?) {
        let scale = servingAmount.flatMap { $0 > 0 ? 100 / $0 : nil }
        self.init(nutriments) { key in
            if let value = Self.valid(nutriments["\(key)_100g"]) {
                return value
            }
            guard let scale, let value = Self.valid(nutriments["\(key)_serving"]) else { return nil }
            return value * scale
        }
    }

    /// Per-serving values: `<key>_serving` as given.
    init(perServingFrom nutriments: [String: Double]) {
        self.init(nutriments) { key in Self.valid(nutriments["\(key)_serving"]) }
    }

    private init(_: [String: Double], value: (String) -> Double?) {
        kcal = Self.energy(kcal: value("energy-kcal"), kJ: value("energy-kj") ?? value("energy"))
        protein = value("proteins")
        carbs = value("carbohydrates")
        fat = value("fat")
        fiber = value("fiber")
        sugar = value("sugars")
        satFat = value("saturated-fat")
        sodiumMg = value("salt").map(Salt.sodiumMg(fromSaltG:)) ?? value("sodium").map { $0 * 1000 }
    }

    /// kcal, else kJ ÷ 4.184. When kcal ≈ kJ the contributor typed the kJ figure into the kcal field: use kJ ÷ 4.184.
    static func energy(kcal: Double?, kJ: Double?) -> Double? {
        if let kcal, let kJ, kJ > 0, abs(kcal - kJ) <= kJ * 0.1 {
            return kJ / OFFFoodMapper.kJPerKcal
        }
        return kcal ?? kJ.map { $0 / OFFFoodMapper.kJPerKcal }
    }
}
