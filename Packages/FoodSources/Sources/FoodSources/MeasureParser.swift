import Core
import Foundation

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

    /// `amount` of `unit` ("kg", "cl", "oz", …) in g or ml; `nil` for unknown units.
    static func convert(_ amount: Double, unit: String) -> (amount: Double, unit: BaseUnit)? {
        let unit = unit.lowercased()
        if unit == "oz" {
            return (amount * gramsPerOunce, .grams)
        }
        return metricUnits[unit].map { (amount * $0.factor, $0.unit) }
    }

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
