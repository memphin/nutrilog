import Core
import Foundation

/// Maps an ``FDCFood`` search result to a ``FoodDraft`` (`origin = .usda`, `sourceID` = FDC ID).
///
/// Nutrients are picked by FDC nutrient ID (else by legacy nutrient number), first usable ID wins:
///
/// | Nutrient  | IDs (number)                                                                    |
/// |-----------|---------------------------------------------------------------------------------|
/// | Energy    | 1008 Energy (208), 1062 Energy kJ (268), 2048 Atwater specific (958), 2047 Atwater general (957) |
/// | Protein   | 1003 (203)                                                                      |
/// | Fat       | 1004 Total lipid (204), 1085 Total fat NLEA (298)                               |
/// | Carbs     | 1005 by difference (205), 1050 by summation (205.2)                             |
/// | Fiber     | 1079 Fiber, total dietary (291), 2033 AOAC 2011.25 (293)                        |
/// | Sugars    | 2000 Total Sugars (269), 1063 Sugars, Total (269.3)                             |
/// | Sat. fat  | 1258 Fatty acids, total saturated (606)                                         |
/// | Sodium    | 1093 Sodium, Na (307)                                                           |
///
/// - Units come from `unitName`: kcal or kJ (÷ 4.184) for energy; g, mg or µg for the rest, converted to g (sodium
///   to mg). An unknown unit makes the value missing. Without `unitName` the nutrient's usual unit is assumed.
/// - Foundation foods have no 1008, only the Atwater energies; the specific factors (2048) are the more accurate.
/// - Values are per 100 g. Branded foods report per 100 g, or per 100 ml when the serving is in ml (the food is
///   then liquid), plus `servingSize`/`servingSizeUnit` which become the default serving.
/// - Negative, non-finite and physically impossible values count as missing (``NutrientValues``).
public enum FDCFoodMapper {
    public enum NutrientID {
        public static let energyKcal = 1008
        public static let energyKJ = 1062
        public static let energyAtwaterSpecific = 2048
        public static let energyAtwaterGeneral = 2047
        public static let protein = 1003
        public static let fat = 1004
        public static let fatNLEA = 1085
        public static let carbsByDifference = 1005
        public static let carbsBySummation = 1050
        public static let fiber = 1079
        public static let fiberAOAC = 2033
        public static let sugars = 2000
        public static let sugarsTotal = 1063
        public static let saturatedFat = 1258
        public static let sodium = 1093
    }

    /// Legacy nutrient numbers of the IDs above, for records that only carry `nutrientNumber`.
    static let idByNumber: [String: Int] = [
        "208": NutrientID.energyKcal, "268": NutrientID.energyKJ,
        "958": NutrientID.energyAtwaterSpecific, "957": NutrientID.energyAtwaterGeneral,
        "203": NutrientID.protein, "204": NutrientID.fat, "298": NutrientID.fatNLEA,
        "205": NutrientID.carbsByDifference, "205.2": NutrientID.carbsBySummation,
        "291": NutrientID.fiber, "293": NutrientID.fiberAOAC,
        "269": NutrientID.sugars, "269.3": NutrientID.sugarsTotal,
        "606": NutrientID.saturatedFat, "307": NutrientID.sodium,
    ]

    /// Food detail page, linked as the source.
    public static func productURL(fdcID: Int) -> URL? {
        URL(string: "https://fdc.nal.usda.gov/food-details/\(fdcID)/nutrients")
    }

    /// `nil` when the food has no FDC IDs.
    public static func map(_ food: FDCFood) -> FoodDraft? {
        guard let fdcID = food.fdcId, fdcID > 0 else { return nil }
        let values = NutrientValues(fdcNutrients: food.foodNutrients).plausiblePer100()
        let serving = serving(food)
        let isLiquid = servingUnit(food) == .milliliters
        let household = OFFFoodMapper.clean(food.householdServingFullText)
        let brand = OFFFoodMapper.clean(food.brandName) ?? OFFFoodMapper.clean(food.brandOwner)

        return FoodDraft(
            origin: .usda,
            sourceID: String(fdcID),
            barcode: food.gtinUpc.flatMap { Barcode.normalize($0) },
            name: OFFFoodMapper.clean(food.name),
            brand: brand,
            nutrients: values.nutrients,
            basis: .per100,
            missingNutrients: values.missing,
            isLiquid: isLiquid,
            serving: serving.map { serving in
                ServingSize(
                    label: household ?? "\(NumberFormatting.compact(serving.amount)) \(serving.unit.symbol)",
                    amount: serving.amount,
                )
            },
            servingDescription: household,
            packageDescription: OFFFoodMapper.clean(food.packageWeight),
            productURL: productURL(fdcID: fdcID),
            ingredientsText: OFFFoodMapper.clean(food.ingredients),
        )
    }

    /// Branded serving in g or ml; `nil` for other data types, unknown units and amounts that aren't above 0 and at
    /// most ``OFFFoodMapper/maximumServing`` (after conversion).
    static func serving(_ food: FDCFood) -> (amount: Double, unit: BaseUnit)? {
        guard let size = food.servingSize, size > 0, size.isFinite, let unit = food.servingSizeUnit,
              let serving = MeasureParser.convert(size, unit: normalizedUnit(unit)),
              let amount = OFFFoodMapper.usableServing(serving.amount)
        else { return nil }
        return (amount, serving.unit)
    }

    /// Whether Branded values are per 100 g or per 100 ml, from `servingSizeUnit`; `nil` when unknown.
    static func servingUnit(_ food: FDCFood) -> BaseUnit? {
        food.servingSizeUnit.flatMap { MeasureParser.convert(1, unit: normalizedUnit($0))?.unit }
    }

    /// FDC's GS1-style unit codes ("GRM", "MLT") as the units ``MeasureParser`` knows.
    private static func normalizedUnit(_ unit: String) -> String {
        let aliases = ["grm": "g", "gm": "g", "mlt": "ml", "mll": "ml"]
        let lowered = unit.trimmingCharacters(in: .whitespaces).lowercased()
        return aliases[lowered] ?? lowered
    }

    // MARK: - Units

    /// `value` in kcal, from kcal or kJ. `defaultUnit` applies when `unitName` is absent.
    static func kcal(_ value: Double, unitName: String?, defaultUnit: String) -> Double? {
        switch (unitName ?? defaultUnit).lowercased() {
        case "kcal": value
        case "kj": value / OFFFoodMapper.kJPerKcal
        default: nil
        }
    }

    /// `value` in grams, from g, mg or µg. `defaultUnit` applies when `unitName` is absent.
    static func grams(_ value: Double, unitName: String?, defaultUnit: String = "g") -> Double? {
        switch (unitName ?? defaultUnit).lowercased() {
        case "g": value
        case "mg": value / 1000
        case "ug", "µg", "μg", "mcg": value / 1_000_000
        default: nil
        }
    }
}

// MARK: - Nutrient resolution

/// FDC `foodNutrients` → ``NutrientValues``.
extension NutrientValues {
    init(fdcNutrients: [FDCNutrient]) {
        typealias IDs = FDCFoodMapper.NutrientID
        var byID: [Int: [FDCNutrient]] = [:]
        for nutrient in fdcNutrients {
            guard let id = nutrient.nutrientId ?? nutrient.nutrientNumber.flatMap({ FDCFoodMapper.idByNumber[$0] })
            else { continue }
            byID[id, default: []].append(nutrient)
        }
        // First usable value over `ids`, converted by `convert`.
        func first(_ ids: [Int], _ convert: (Int, FDCNutrient, Double) -> Double?) -> Double? {
            for id in ids {
                for nutrient in byID[id] ?? [] {
                    if let raw = Self.valid(nutrient.value), let value = Self.valid(convert(id, nutrient, raw)) {
                        return value
                    }
                }
            }
            return nil
        }
        func grams(_ ids: Int...) -> Double? {
            first(ids) { _, nutrient, raw in FDCFoodMapper.grams(raw, unitName: nutrient.unitName) }
        }

        self.init(
            kcal: first([IDs.energyKcal, IDs.energyKJ, IDs.energyAtwaterSpecific, IDs.energyAtwaterGeneral]) { id, nutrient, raw in
                FDCFoodMapper.kcal(raw, unitName: nutrient.unitName, defaultUnit: id == IDs.energyKJ ? "kJ" : "kcal")
            },
            protein: grams(IDs.protein),
            carbs: grams(IDs.carbsByDifference, IDs.carbsBySummation),
            fat: grams(IDs.fat, IDs.fatNLEA),
            fiber: grams(IDs.fiber, IDs.fiberAOAC),
            sugar: grams(IDs.sugars, IDs.sugarsTotal),
            satFat: grams(IDs.saturatedFat),
            sodiumMg: first([IDs.sodium]) { _, nutrient, raw in
                FDCFoodMapper.grams(raw, unitName: nutrient.unitName, defaultUnit: "mg").map { $0 * 1000 }
            },
        )
    }
}
