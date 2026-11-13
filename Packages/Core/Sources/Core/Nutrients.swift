import Foundation

/// A set of nutrient amounts: either "per 100 g/ml" (a food's base values) or absolute totals
/// (a diary entry, a day). Mandatory macros are non-optional; the rest are optional because
/// many food labels and databases omit them.
///
/// Rules (SPEC §5.1 FR-2, §8, backlog #1):
/// - Energy is stored, never recomputed from macros — the stored `kcal` always wins.
/// - Optional addition: `nil + x = x`, `nil + nil = nil`.
public struct Nutrients: Hashable, Sendable, Codable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double?
    public var sugarG: Double?
    public var satFatG: Double?
    public var sodiumMg: Double?
    /// Caffeine in mg (coffee, tea, cola, energy drinks…). Optional like the other extras: most foods don't state it.
    public var caffeineMg: Double?

    public init(
        kcal: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        fiberG: Double? = nil,
        sugarG: Double? = nil,
        satFatG: Double? = nil,
        sodiumMg: Double? = nil,
        caffeineMg: Double? = nil,
    ) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.satFatG = satFatG
        self.sodiumMg = sodiumMg
        self.caffeineMg = caffeineMg
    }

    public static let zero = Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)

    /// Scales per-100 g (or ml) values to an absolute amount.
    public func scaled(toGrams grams: Double) -> Nutrients {
        scaled(by: grams / 100)
    }

    /// Multiplies every value by `factor`.
    public func scaled(by factor: Double) -> Nutrients {
        Nutrients(
            kcal: kcal * factor,
            proteinG: proteinG * factor,
            carbsG: carbsG * factor,
            fatG: fatG * factor,
            fiberG: fiberG.map { $0 * factor },
            sugarG: sugarG.map { $0 * factor },
            satFatG: satFatG.map { $0 * factor },
            sodiumMg: sodiumMg.map { $0 * factor },
            caffeineMg: caffeineMg.map { $0 * factor },
        )
    }

    /// Converts values given for one serving of `servingGrams` into per-100 g values.
    /// Used by the custom-food form's "per serving" mode (backlog #9).
    public static func per100(fromServing perServing: Nutrients, servingGrams: Double) -> Nutrients {
        precondition(servingGrams > 0, "serving size must be positive")
        return perServing.scaled(by: 100 / servingGrams)
    }

    public static func + (lhs: Nutrients, rhs: Nutrients) -> Nutrients {
        Nutrients(
            kcal: lhs.kcal + rhs.kcal,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG: lhs.carbsG + rhs.carbsG,
            fatG: lhs.fatG + rhs.fatG,
            fiberG: addOptional(lhs.fiberG, rhs.fiberG),
            sugarG: addOptional(lhs.sugarG, rhs.sugarG),
            satFatG: addOptional(lhs.satFatG, rhs.satFatG),
            sodiumMg: addOptional(lhs.sodiumMg, rhs.sodiumMg),
            caffeineMg: addOptional(lhs.caffeineMg, rhs.caffeineMg),
        )
    }

    public static func += (lhs: inout Nutrients, rhs: Nutrients) {
        lhs = lhs + rhs
    }

    /// Sum of a sequence; `.zero` when empty.
    public static func sum(_ items: some Sequence<Nutrients>) -> Nutrients {
        items.reduce(.zero, +)
    }

    private static func addOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (l?, r?): l + r
        case let (l?, nil): l
        case let (nil, r?): r
        case (nil, nil): nil
        }
    }
}

// MARK: - Energy plausibility

public extension Nutrients {
    /// Energy implied by macros using Atwater general factors (4 / 4 / 9 kcal per g).
    var kcalFromMacros: Double {
        proteinG * Energy.kcalPerGramProtein + carbsG * Energy.kcalPerGramCarbs + fatG * Energy.kcalPerGramFat
    }

    /// Relative difference between stored kcal and the 4/4/9 estimate, e.g. 0.2 = 20 %.
    /// `nil` when both are ~0 (water, salt, …).
    var energyMismatch: Double? {
        let estimate = kcalFromMacros
        let reference = max(kcal, estimate)
        guard reference > 0.5 else { return nil }
        return abs(kcal - estimate) / reference
    }

    /// True when stored energy and macros disagree by more than `tolerance` (default 15 %, backlog #9).
    /// Only a warning: fiber, alcohol and polyols legitimately cause gaps.
    func hasImplausibleEnergy(tolerance: Double = 0.15) -> Bool {
        (energyMismatch ?? 0) > tolerance
    }
}

// MARK: - Salt / sodium

public enum Salt {
    /// Salt (g) → sodium (mg). Salt is ~40 % sodium: 1 g salt = 400 mg sodium (SPEC §9).
    public static func sodiumMg(fromSaltG salt: Double) -> Double {
        salt * 400
    }

    /// Sodium (mg) → salt (g).
    public static func saltG(fromSodiumMg sodium: Double) -> Double {
        sodium / 400
    }
}
