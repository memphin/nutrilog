import Core
import Foundation

/// The mapped nutrient values of one basis (per 100 or per serving), shared by the source mappers: each source
/// fills it in its own extension (OFF keys, FDC nutrient ids); `nil` means missing.
struct NutrientValues {
    /// Above this, energy per 100 g is impossible (pure fat is 900 kcal; slack for kJ rounding).
    static let maxKcalPer100 = 902.0
    /// Above this, protein + carbs + fat per 100 g is impossible (slack for label rounding).
    static let maxMacroSumPer100 = 105.0
    /// Salt above 100 g per 100 g is impossible: 100 g × 400 mg.
    static let maxSodiumMgPer100 = 40000.0
    /// Above this, caffeine per 100 g/ml is not a food: instant coffee powder, the richest, has ~4 g/100 g.
    /// Catches mg typed into OFF's gram field (a 32 mg/100 ml energy drink saved as 32 g → 32 000 mg).
    static let maxCaffeineMgPer100 = 5000.0

    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var sugar: Double?
    var satFat: Double?
    var sodiumMg: Double?
    var caffeineMg: Double?

    /// Drops per-100 values that can't be true: energy > ~900 kcal, any macro > 100 g, protein + carbs + fat
    /// > ~105 g (all three dropped — there's no telling which is wrong), salt > 100 g, caffeine > 5 g.
    func plausiblePer100() -> NutrientValues {
        var values = self
        let atMost100: (Double?) -> Double? = { value in value.flatMap { $0 <= 100 ? $0 : nil } }
        values.kcal = kcal.flatMap { $0 <= Self.maxKcalPer100 ? $0 : nil }
        values.protein = atMost100(protein)
        values.carbs = atMost100(carbs)
        values.fat = atMost100(fat)
        values.fiber = atMost100(fiber)
        values.sugar = atMost100(sugar)
        values.satFat = atMost100(satFat)
        values.sodiumMg = sodiumMg.flatMap { $0 <= Self.maxSodiumMgPer100 ? $0 : nil }
        values.caffeineMg = caffeineMg.flatMap { $0 <= Self.maxCaffeineMgPer100 ? $0 : nil }
        let macroSum = (values.protein ?? 0) + (values.carbs ?? 0) + (values.fat ?? 0)
        if macroSum > Self.maxMacroSumPer100 {
            values.protein = nil
            values.carbs = nil
            values.fat = nil
        }
        return values
    }

    /// `value` when finite and not negative, else `nil`.
    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    var isEmpty: Bool {
        [kcal, protein, carbs, fat, fiber, sugar, satFat, sodiumMg, caffeineMg].allSatisfy { $0 == nil }
    }

    var missing: Set<FoodDraft.MandatoryNutrient> {
        var missing: Set<FoodDraft.MandatoryNutrient> = []
        if kcal == nil {
            missing.insert(.energy)
        }
        if protein == nil {
            missing.insert(.protein)
        }
        if carbs == nil {
            missing.insert(.carbs)
        }
        if fat == nil {
            missing.insert(.fat)
        }
        return missing
    }

    var nutrients: Nutrients {
        Nutrients(
            kcal: kcal ?? 0,
            proteinG: protein ?? 0,
            carbsG: carbs ?? 0,
            fatG: fat ?? 0,
            fiberG: fiber,
            sugarG: sugar,
            satFatG: satFat,
            sodiumMg: sodiumMg,
            caffeineMg: caffeineMg,
        )
    }
}
