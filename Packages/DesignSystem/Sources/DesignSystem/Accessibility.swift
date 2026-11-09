import Foundation

/// Spoken descriptions for charts and progress views (FR-73). Kept as pure functions so they are unit-tested.
public enum A11y {
    /// "Protein 120 of 160 grams", "Protein 120 grams" when there is no target.
    public static func progress(label: String, value: Double, target: Double?, unit: String) -> String {
        let spokenUnit = spoken(unit)
        if let target, target > 0 {
            return "\(label) \(format(value)) of \(format(target)) \(spokenUnit)"
        }
        return "\(label) \(format(value)) \(spokenUnit)"
    }

    /// "1,250 calories remaining of 2,000" / "150 calories over target of 2,000".
    public static func energyRemaining(consumed: Double, target: Double?) -> String {
        guard let target, target > 0 else { return "\(format(consumed)) calories eaten, no target set" }
        let remaining = target - consumed
        if remaining >= 0 {
            return "\(format(remaining)) calories remaining of \(format(target))"
        }
        return "\(format(-remaining)) calories over target of \(format(target))"
    }

    static func spoken(_ unit: String) -> String {
        switch unit {
        case "g": "grams"
        case "mg": "milligrams"
        case "ml": "millilitres"
        case "kcal": "calories"
        case "kJ": "kilojoules"
        default: unit
        }
    }

    static func format(_ value: Double) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
    }
}

/// Fraction of a target reached, clamped to 0…1 for drawing; `isOver` tells whether to show the over state.
public struct Progress: Equatable, Sendable {
    public let fraction: Double
    public let isOver: Bool

    public init(value: Double, target: Double?) {
        guard let target, target > 0 else {
            fraction = 0
            isOver = false
            return
        }
        let raw = value / target
        fraction = min(max(raw, 0), 1)
        isOver = raw > 1.0001
    }
}
