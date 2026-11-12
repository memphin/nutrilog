import Core
import Foundation

/// Upper bounds for user-entered amounts and nutrients, the one source of truth for the repositories and the app's
/// input fields. Generous on purpose: they only keep pasted nonsense (`inf`, a 23-digit number) out of the database,
/// where it would break exports, backups and charts.
public enum EntryLimits {
    /// Grams or ml in one entry (diary, plan, saved-meal item, water, serving).
    public static let maxAmount: Double = 100_000 /* g or ml per entry */
    /// Kilocalories in one entry or per 100 g of a food.
    public static let maxKcal: Double = 100_000
    /// Grams of a macro (or mg of sodium) in one entry or per 100 g of a food.
    public static let maxMacroGrams: Double = 100_000

    static let tooLarge = String(localized: "That amount is too large.", bundle: .module)
    static let notANumber = String(localized: "That amount is not a number.", bundle: .module)

    /// Throws unless `amount` is finite and at most ``maxAmount``. The "greater than zero" checks stay with the callers.
    static func validate(amount: Double) throws {
        guard amount.isFinite else { throw PersistenceError.validation(notANumber) }
        guard amount <= maxAmount else { throw PersistenceError.validation(tooLarge) }
    }

    /// Throws unless every value of `nutrients` (optional ones when present) is finite and its magnitude within the
    /// limits. The sign isn't checked: quick-adds never had to be non-negative.
    static func validate(_ nutrients: Nutrients) throws {
        let values: [(Double?, Double)] = [
            (nutrients.kcal, maxKcal), (nutrients.proteinG, maxMacroGrams), (nutrients.carbsG, maxMacroGrams),
            (nutrients.fatG, maxMacroGrams), (nutrients.fiberG, maxMacroGrams), (nutrients.sugarG, maxMacroGrams),
            (nutrients.satFatG, maxMacroGrams), (nutrients.sodiumMg, maxMacroGrams),
        ]
        for case let (value?, limit) in values {
            guard value.isFinite else { throw PersistenceError.validation(notANumber) }
            guard abs(value) <= limit else { throw PersistenceError.validation(tooLarge) }
        }
    }

    /// Throws unless every value of a computed snapshot is finite (amount × per-100 values of a stored food).
    static func validateFinite(_ nutrients: Nutrients) throws {
        let values = [
            nutrients.kcal, nutrients.proteinG, nutrients.carbsG, nutrients.fatG,
            nutrients.fiberG, nutrients.sugarG, nutrients.satFatG, nutrients.sodiumMg,
        ]
        guard values.allSatisfy({ $0?.isFinite ?? true }) else { throw PersistenceError.validation(notANumber) }
    }
}
