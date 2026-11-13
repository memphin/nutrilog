import Core
import Foundation

// MARK: - Measure parsing

/// Reads an amount and unit from OFF text such as "30 g", "1 portion (30g)", "2 keksa (25 g)", "0,5 l", "33 cl",
/// "1 oz (28 g)". Metric units (`BaseUnit.metricUnits`) win over ounces; result is in grams or millilitres.
public enum MeasureParser {
    public static let gramsPerOunce = 28.349_523_125

    /// `amount` of `unit` ("kg", "cl", "oz", …, any case) in g or ml; `nil` for unknown units.
    public static func convert(_ amount: Double, unit: String) -> (amount: Double, unit: BaseUnit)? {
        if unit.lowercased() == "oz" {
            return (amount * gramsPerOunce, .grams)
        }
        return BaseUnit.convert(amount, metricUnit: unit)
    }

    /// Also reads multipacks ("2 x 125 ml" → 250 ml, "×" too), fractions ("1/2 l" → 500 ml, "1 1/2 oz") and skips
    /// amounts that may carry a thousands separator ("1.000 g", "1,500 kg": 1 or 1000?) — a wrong serving weight
    /// scales per-serving values wrongly, so no reading beats a guess.
    public static func parse(_ text: String) -> (amount: Double, unit: BaseUnit)? {
        let pattern = #/(?i)(?:(?<count>\d+(?:[.,]\d+)?)\s*[x×]\s*)?(?:(?<whole>\d+)\s+(?=\d+\s*\/\s*\d))?(?<number>\d+(?:[.,]\d+)?)(?:\s*\/\s*(?<denominator>\d+))?\s*(?<unit>kg|mg|grams|gram|gr|g|ml|cl|dl|l|oz)\b/#
        var ounces: Double?
        for match in text.matches(of: pattern) {
            guard let amount = amount(match.output) else { continue }
            if let metric = BaseUnit.convert(amount, metricUnit: String(match.output.unit)) {
                return metric
            }
            if ounces == nil {
                ounces = amount * gramsPerOunce
            }
        }
        return ounces.map { ($0, .grams) }
    }

    /// The positive amount a match describes (count × (whole + number / denominator)), or `nil` when it is
    /// ambiguous or unusable.
    private static func amount(
        _ output: (Substring, count: Substring?, whole: Substring?, number: Substring, denominator: Substring?, unit: Substring),
    ) -> Double? {
        let parts = [output.count, output.number].compactMap(\.self)
        guard !parts.contains(where: isAmbiguousThousands), var amount = LenientNumber.parse(String(output.number))
        else { return nil }
        if let denominator = output.denominator {
            guard !output.number.contains(where: { $0 == "." || $0 == "," }),
                  let denominator = Double(denominator), denominator > 0
            else { return nil }
            amount /= denominator
            amount += output.whole.flatMap { Double($0) } ?? 0
        }
        if let count = output.count {
            guard let count = LenientNumber.parse(String(count)) else { return nil }
            amount *= count
        }
        guard amount > 0, amount.isFinite else { return nil }
        return amount
    }

    /// "1.000" or "1,500": one to three digits (not a lone 0), a separator and exactly three digits — a thousands
    /// separator or a decimal one, no way to tell.
    private static func isAmbiguousThousands(_ number: Substring) -> Bool {
        number.wholeMatch(of: #/[1-9]\d{0,2}[.,]\d{3}/#) != nil
    }
}
