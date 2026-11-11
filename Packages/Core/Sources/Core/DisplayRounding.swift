import Foundation

/// Display rounding rules. Storage keeps full precision; only presentation rounds.
///
/// - Energy: whole kcal.
/// - Macros, fiber, sugar, sat fat: whole grams from 10 g, otherwise one decimal (0.4 g stays visible).
/// - Sodium, caffeine: whole mg.
public enum DisplayRounding {
    public static func kcal(_ value: Double) -> Int {
        Int(value.rounded())
    }

    public static func grams(_ value: Double) -> Double {
        if abs(value) >= 10 {
            return value.rounded()
        }
        return (value * 10).rounded() / 10
    }

    public static func milligrams(_ value: Double) -> Int {
        Int(value.rounded())
    }

    /// "12", "4.5", "0" — trailing ".0" dropped.
    public static func gramsText(_ value: Double) -> String {
        NumberFormatting.compact(grams(value))
    }
}

public extension Nutrients {
    /// Copy rounded for display (kcal whole, grams per `DisplayRounding.grams`).
    var displayRounded: Nutrients {
        Nutrients(
            kcal: Double(DisplayRounding.kcal(kcal)),
            proteinG: DisplayRounding.grams(proteinG),
            carbsG: DisplayRounding.grams(carbsG),
            fatG: DisplayRounding.grams(fatG),
            fiberG: fiberG.map(DisplayRounding.grams),
            sugarG: sugarG.map(DisplayRounding.grams),
            satFatG: satFatG.map(DisplayRounding.grams),
            sodiumMg: sodiumMg.map { Double(DisplayRounding.milligrams($0)) },
            caffeineMg: caffeineMg.map { Double(DisplayRounding.milligrams($0)) },
        )
    }
}
