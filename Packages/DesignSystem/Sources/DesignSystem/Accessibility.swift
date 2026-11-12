import Foundation

/// Spoken descriptions for charts and progress views (FR-73). Kept as pure functions so they are unit-tested.
/// Numbers follow `locale` (the user's by default); tests pass a fixed one.
public enum A11y {
    /// "Protein 120 of 160 grams", "Protein 120 grams" when there is no target.
    public static func progress(
        label: String, value: Double, target: Double?, unit: String, locale: Locale = .current,
    ) -> String {
        let spokenUnit = spoken(unit)
        let valueText = format(value, locale: locale)
        if let target, target > 0 {
            let targetText = format(target, locale: locale)
            return String(
                localized: "\(label) \(valueText) of \(targetText) \(spokenUnit)", bundle: .module,
                comment: "Spoken progress, e.g. “Protein 120 of 160 grams”",
            )
        }
        return String(
            localized: "\(label) \(valueText) \(spokenUnit)", bundle: .module,
            comment: "Spoken progress without a target, e.g. “Protein 120 grams”",
        )
    }

    /// "1,250 calories remaining of 2,000" / "150 calories over target of 2,000"; with `unit` "kJ",
    /// "5,230 kilojoules remaining of 8,368". Values are in `unit`.
    public static func energyRemaining(
        consumed: Double, target: Double?, unit: String = "kcal", locale: Locale = .current,
    ) -> String {
        let spokenUnit = spoken(unit)
        guard let target, target > 0 else {
            let consumedText = format(consumed, locale: locale)
            return String(localized: "\(consumedText) \(spokenUnit) eaten, no target set", bundle: .module)
        }
        let remaining = target - consumed
        let targetText = format(target, locale: locale)
        if remaining >= 0 {
            let remainingText = format(remaining, locale: locale)
            return String(localized: "\(remainingText) \(spokenUnit) remaining of \(targetText)", bundle: .module)
        }
        let overText = format(-remaining, locale: locale)
        return String(localized: "\(overText) \(spokenUnit) over target of \(targetText)", bundle: .module)
    }

    /// "Protein 12 grams, carbs 30 grams, fat 8 grams" for a compact macro line.
    public static func macros(protein: Double, carbs: Double, fat: Double, locale: Locale = .current) -> String {
        let proteinText = format(protein, locale: locale)
        let carbsText = format(carbs, locale: locale)
        let fatText = format(fat, locale: locale)
        return String(
            localized: "Protein \(proteinText) grams, carbs \(carbsText) grams, fat \(fatText) grams", bundle: .module,
        )
    }

    static func spoken(_ unit: String) -> String {
        switch unit {
        case "g": String(localized: "grams", bundle: .module, comment: "Spoken unit after a number")
        case "mg": String(localized: "milligrams", bundle: .module, comment: "Spoken unit after a number")
        case "ml": String(localized: "millilitres", bundle: .module, comment: "Spoken unit after a number")
        case "kcal": String(localized: "calories", bundle: .module, comment: "Spoken unit after a number")
        case "kJ": String(localized: "kilojoules", bundle: .module, comment: "Spoken unit after a number")
        default: unit
        }
    }

    /// Whole number with the locale's grouping ("1,250" in English, "1.250" in Croatian).
    static func format(_ value: Double, locale: Locale = .current) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
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
