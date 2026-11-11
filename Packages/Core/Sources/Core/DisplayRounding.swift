import Foundation

/// Display rounding rules. Storage keeps full precision; only presentation rounds.
///
/// - Energy: whole kcal.
/// - Macros, fiber, sugar, sat fat: whole grams from 10 g, otherwise one decimal (0.4 g stays visible).
/// - Sodium: whole mg.
public enum DisplayRounding {
    /// 2^63 — the first magnitude `Int` cannot hold. `Double(Int.max)` rounds up to exactly this value, so comparing
    /// against `Double(Int.max)` would let 2^63 through and trap.
    static let intBound = 9_223_372_036_854_775_808.0

    /// `value` rounded to the nearest whole number (halves away from zero) as an `Int`, without ever trapping:
    /// NaN and ±infinity give 0, magnitudes beyond `Int`'s range clamp to `Int.min` / `Int.max`.
    public static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= intBound {
            return Int.max
        }
        if rounded < -intBound {
            return Int.min
        }
        return Int(rounded) // -2^63 itself is exactly Int.min
    }

    public static func kcal(_ value: Double) -> Int {
        whole(value)
    }

    public static func grams(_ value: Double) -> Double {
        if abs(value) >= 10 {
            return value.rounded()
        }
        return (value * 10).rounded() / 10
    }

    public static func milligrams(_ value: Double) -> Int {
        whole(value)
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
        )
    }
}
