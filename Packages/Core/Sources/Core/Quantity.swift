import Foundation

/// Base unit of a food: grams for solids, millilitres for liquids (`food.is_liquid`).
/// Nutrients are always "per 100 base units"; we treat 1 ml ≈ 1 g for scaling.
public enum BaseUnit: String, Sendable, Codable, CaseIterable {
    case grams = "g"
    case milliliters = "ml"

    public init(isLiquid: Bool) {
        self = isLiquid ? .milliliters : .grams
    }

    public var symbol: String {
        rawValue
    }

    /// Metric unit symbols, lowercase ("kg", "cl", "gram", …) → the factor to grams or millilitres and which of the two.
    /// The one unit table of the text parsers (FoodSources' `MeasureParser`, ``MealDescription``).
    public static let metricUnits: [String: (factor: Double, unit: BaseUnit)] = [
        "kg": (1000, .grams), "mg": (0.001, .grams),
        "g": (1, .grams), "gr": (1, .grams), "gram": (1, .grams), "grams": (1, .grams),
        "ml": (1, .milliliters), "cl": (10, .milliliters), "dl": (100, .milliliters), "l": (1000, .milliliters),
    ]

    /// `amount` of the metric unit `symbol` (any case) in grams or millilitres; `nil` for symbols not in
    /// ``metricUnits``.
    public static func convert(_ amount: Double, metricUnit symbol: String) -> (amount: Double, unit: BaseUnit)? {
        metricUnits[symbol.lowercased()].map { (amount * $0.factor, $0.unit) }
    }
}

/// A named portion of a food, e.g. "1 slice" = 25 g.
public struct ServingSize: Hashable, Sendable, Codable {
    public var label: String
    /// Amount in the food's base unit (g or ml).
    public var amount: Double

    public init(label: String, amount: Double) {
        self.label = label
        self.amount = amount
    }
}

/// What the user typed in the quantity sheet.
public enum Quantity: Hashable, Sendable, Codable {
    /// Plain amount in the food's base unit (g or ml).
    case base(Double)
    /// `count` × a serving, e.g. 1.5 × "1 slice (25 g)".
    case servings(count: Double, serving: ServingSize)

    /// Amount in the food's base unit — the value stored in `diary_entry.grams`.
    public var baseAmount: Double {
        switch self {
        case let .base(amount): amount
        case let .servings(count, serving): count * serving.amount
        }
    }

    /// Human label stored as `diary_entry.serving_label`, e.g. "2 × slice", "1.5 × plate" (in the user's locale:
    /// "1,5 × plate" in Croatian). `nil` for base amounts (the base amount is shown from `grams` directly).
    public var servingLabel: String? {
        servingLabel(locale: .current)
    }

    /// ``servingLabel`` with the count written for `locale`. Only the text after "× " is ever matched back to a
    /// serving, so the decimal separator doesn't matter to readers of stored labels.
    public func servingLabel(locale: Locale) -> String? {
        switch self {
        case .base:
            nil
        case let .servings(count, serving):
            "\(NumberFormatting.compact(count, locale: locale)) × \(serving.label)"
        }
    }

    /// Nutrients for this quantity of a food with the given per-100 values.
    public func nutrients(per100: Nutrients) -> Nutrients {
        per100.scaled(toGrams: baseAmount)
    }
}

public enum NumberFormatting {
    /// "1", "1.5", "0.25" — no trailing zeros, up to 2 decimals, locale-independent: for machine text (CSV export).
    /// Text shown to the user goes through ``compact(_:locale:)``.
    /// Total for every `Double`: NaN reads "NaN", infinities "∞" / "-∞", and whole numbers beyond `Int`'s range
    /// are written out as plain digits (never in scientific notation).
    public static func compact(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }
        if value.isInfinite {
            return value < 0 ? "-∞" : "∞"
        }
        let rounded = (value * 100).rounded() / 100
        if !rounded.isFinite {
            // `value * 100` overflowed: the value is huge, so it is whole already.
            return String(format: "%.0f", value)
        }
        if rounded == rounded.rounded() {
            if abs(rounded) < DisplayRounding.intBound {
                return String(Int(rounded))
            }
            return String(format: "%.0f", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return text
    }

    /// ``compact(_:)`` for display: the same digits with `locale`'s decimal separator ("1,5" in Croatian) and, like
    /// ``compact(_:)``, no grouping, so the text also reads back in a number field (which accepts "," and ".").
    public static func compact(_ value: Double, locale: Locale) -> String {
        let text = compact(value)
        guard let separator = locale.decimalSeparator, separator != "." else { return text }
        return text.replacingOccurrences(of: ".", with: separator)
    }
}
