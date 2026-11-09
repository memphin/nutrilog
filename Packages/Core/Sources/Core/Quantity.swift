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

    /// Human label stored as `diary_entry.serving_label`, e.g. "2 slices", "150 g". `nil` for base amounts
    /// (the base amount is shown from `grams` directly).
    public var servingLabel: String? {
        switch self {
        case .base:
            nil
        case let .servings(count, serving):
            "\(NumberFormatting.compact(count)) × \(serving.label)"
        }
    }

    /// Nutrients for this quantity of a food with the given per-100 values.
    public func nutrients(per100: Nutrients) -> Nutrients {
        per100.scaled(toGrams: baseAmount)
    }
}

public enum NumberFormatting {
    /// "1", "1.5", "0.25" — no trailing zeros, up to 2 decimals, locale-independent.
    public static func compact(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return text
    }
}
