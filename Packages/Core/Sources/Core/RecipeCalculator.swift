import Foundation

/// One ingredient of a recipe: an amount and the ingredient's nutrients per 100 g/ml at the time it was added.
public struct RecipeIngredientAmount: Hashable, Sendable {
    public var grams: Double
    public var per100: Nutrients

    public init(grams: Double, per100: Nutrients) {
        self.grams = grams
        self.per100 = per100
    }

    public var nutrients: Nutrients {
        per100.scaled(toGrams: grams)
    }
}

/// What a recipe works out to (FR-25, backlog #31).
public struct RecipeNutrition: Hashable, Sendable {
    /// Nutrients of the whole batch.
    public var total: Nutrients
    /// Sum of the ingredient amounts.
    public var rawWeightG: Double
    /// Weight the per-100 values refer to: the cooked weight when given, else the raw weight.
    public var finalWeightG: Double
    public var per100: Nutrients
    /// Weight of one serving (`finalWeight / servings`); nil without a servings count.
    public var servingG: Double?

    /// Nutrients of one serving; nil without a servings count.
    public var perServing: Nutrients? {
        servingG.map { per100.scaled(toGrams: $0) }
    }

    /// Cooked ÷ raw weight: 0.8 means the dish lost 20 % (water) while cooking.
    public var yield: Double {
        rawWeightG > 0 ? finalWeightG / rawWeightG : 1
    }
}

public enum RecipeCalculator {
    /// Nutrients per 100 g and per serving of a recipe.
    ///
    /// - `cookedWeightG`: weight of the finished dish. Cooking changes the weight (water evaporates or is absorbed)
    ///   but not the nutrients, so the totals are spread over the cooked weight. Nil or ≤ 0: the raw weight is used.
    /// - `servings`: how many portions the batch makes; nil or ≤ 0: no serving.
    ///
    /// Returns nil for a recipe without any positive ingredient amount.
    public static func nutrition(
        ingredients: [RecipeIngredientAmount],
        cookedWeightG: Double? = nil,
        servings: Double? = nil,
    ) -> RecipeNutrition? {
        let used = ingredients.filter { $0.grams > 0 && $0.grams.isFinite }
        let raw = used.reduce(0) { $0 + $1.grams }
        guard raw > 0 else { return nil }
        let total = Nutrients.sum(used.map(\.nutrients))
        let final = cookedWeightG.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? raw
        let servingG = servings.flatMap { $0 > 0 && $0.isFinite ? final / $0 : nil }
        return RecipeNutrition(
            total: total, rawWeightG: raw, finalWeightG: final, per100: total.scaled(by: 100 / final), servingG: servingG,
        )
    }

    /// Ingredient amounts scaled for a "re-cook" of a different size, e.g. factor 1.5 for one and a half batches.
    public static func scaled(_ ingredients: [RecipeIngredientAmount], by factor: Double) -> [RecipeIngredientAmount] {
        ingredients.map { RecipeIngredientAmount(grams: $0.grams * factor, per100: $0.per100) }
    }
}
