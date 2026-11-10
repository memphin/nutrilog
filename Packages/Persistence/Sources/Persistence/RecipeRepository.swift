import Core
import Foundation
import GRDB

/// One ingredient of a recipe (`recipe_ingredient`): an amount plus a snapshot of the ingredient's per-100 values,
/// so the recipe stays the same when the ingredient food is edited or deleted later.
public struct RecipeIngredient: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "recipe_ingredient"

    public var id: String
    public var recipeID: String
    /// The food the snapshot was taken from; nil once that food was hard-deleted.
    public var foodID: String?
    public var displayName: String
    public var grams: Double
    public var kcal100: Double
    public var proteinG100: Double
    public var carbsG100: Double
    public var fatG100: Double
    public var fiberG100: Double?
    public var sugarG100: Double?
    public var satFatG100: Double?
    public var sodiumMg100: Double?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, grams, revision
        case recipeID = "recipe_id"
        case foodID = "food_id"
        case displayName = "display_name"
        case kcal100 = "kcal_100"
        case proteinG100 = "protein_g_100"
        case carbsG100 = "carbs_g_100"
        case fatG100 = "fat_g_100"
        case fiberG100 = "fiber_g_100"
        case sugarG100 = "sugar_g_100"
        case satFatG100 = "sat_fat_g_100"
        case sodiumMg100 = "sodium_mg_100"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(id: String = newID(), recipeID: String = "", foodID: String?, displayName: String, grams: Double, per100: Nutrients) {
        self.id = id
        self.recipeID = recipeID
        self.foodID = foodID
        self.displayName = displayName
        self.grams = grams
        kcal100 = per100.kcal
        proteinG100 = per100.proteinG
        carbsG100 = per100.carbsG
        fatG100 = per100.fatG
        fiberG100 = per100.fiberG
        sugarG100 = per100.sugarG
        satFatG100 = per100.satFatG
        sodiumMg100 = per100.sodiumMg
        sortOrder = 0
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }

    /// A new ingredient with a snapshot of `food`'s current values.
    public init(food: Food, grams: Double) {
        self.init(foodID: food.id, displayName: food.name, grams: grams, per100: food.per100)
    }

    public var per100: Nutrients {
        Nutrients(
            kcal: kcal100, proteinG: proteinG100, carbsG: carbsG100, fatG: fatG100,
            fiberG: fiberG100, sugarG: sugarG100, satFatG: satFatG100, sodiumMg: sodiumMg100,
        )
    }

    public var amount: RecipeIngredientAmount {
        RecipeIngredientAmount(grams: grams, per100: per100)
    }

    /// Nutrients of this ingredient's amount.
    public var nutrients: Nutrients {
        per100.scaled(toGrams: grams)
    }
}

/// A recipe: a food with `source = recipe` plus its ingredients (FR-25, backlog #31).
public struct Recipe: Hashable, Identifiable, Sendable {
    public var detail: FoodDetail
    public var ingredients: [RecipeIngredient]

    public var id: String {
        detail.food.id
    }

    public var food: Food {
        detail.food
    }

    public var nutrition: RecipeNutrition? {
        RecipeCalculator.nutrition(
            ingredients: ingredients.map(\.amount), cookedWeightG: food.cookedWeightG, servings: food.servingsCount,
        )
    }
}

/// What the recipe editor saves.
public struct RecipeDraft: Hashable, Sendable {
    /// nil for a new recipe.
    public var id: String?
    public var name: String
    public var notes: String?
    public var ingredients: [RecipeIngredient]
    public var cookedWeightG: Double?
    public var servingsCount: Double?

    public init(
        id: String? = nil, name: String, notes: String? = nil, ingredients: [RecipeIngredient],
        cookedWeightG: Double? = nil, servingsCount: Double? = nil,
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.ingredients = ingredients
        self.cookedWeightG = cookedWeightG
        self.servingsCount = servingsCount
    }

    public init(_ recipe: Recipe) {
        self.init(
            id: recipe.id, name: recipe.food.name, notes: recipe.food.notes, ingredients: recipe.ingredients,
            cookedWeightG: recipe.food.cookedWeightG, servingsCount: recipe.food.servingsCount,
        )
    }

    public var nutrition: RecipeNutrition? {
        RecipeCalculator.nutrition(ingredients: ingredients.map(\.amount), cookedWeightG: cookedWeightG, servings: servingsCount)
    }
}

/// Recipes: save (create, edit, "re-cook" with new weights), read and duplicate.
///
/// The recipe's per-100 values are computed from the ingredient snapshots and stored on the food, so everything that
/// works with foods (search, logging, favorites, saved meals) works with recipes. Diary entries keep their own
/// snapshot, so editing a recipe never changes what was logged before (NFR-4).
public struct RecipeRepository: Sendable {
    /// Label of the serving the repository manages for a recipe with a servings count.
    public static let servingLabel = "serving"

    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Creates the recipe, or updates it when `draft.id` is set. Ingredients missing from the draft are soft-deleted.
    /// With a servings count the recipe gets a default serving of `final weight ÷ servings`; without one that
    /// serving is removed.
    @discardableResult
    public func save(_ draft: RecipeDraft) throws -> Recipe {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersistenceError.validation("A recipe needs a name.") }
        guard let nutrition = draft.nutrition else { throw PersistenceError.validation("A recipe needs at least one ingredient.") }
        if let id = draft.id, draft.ingredients.contains(where: { $0.foodID == id }) {
            throw PersistenceError.validation("A recipe can't contain itself.")
        }
        let now = clock.now()
        return try database.writer.write { db in
            var detail: FoodDetail
            if let id = draft.id {
                guard let existing = try FoodRepository.detail(db, id: id), existing.food.source == .recipe else {
                    throw PersistenceError.notFound(id)
                }
                detail = existing
                detail.food.deletedAt = nil
            } else {
                detail = FoodDetail(food: Food(name: name, source: .recipe, per100: nutrition.per100))
            }
            detail.food.name = name
            detail.food.notes = (draft.notes?.isEmpty ?? true) ? nil : draft.notes
            detail.food.per100 = nutrition.per100
            detail.food.dataQuality = .complete
            detail.food.cookedWeightG = draft.cookedWeightG.flatMap { $0 > 0 ? $0 : nil }
            detail.food.servingsCount = draft.servingsCount.flatMap { $0 > 0 ? $0 : nil }

            // The managed "serving".
            let managed = detail.servings.firstIndex { $0.label == Self.servingLabel }
            if let servingG = nutrition.servingG {
                if let managed {
                    detail.servings[managed].grams = servingG
                    detail.food.defaultServingID = detail.servings[managed].id
                } else {
                    let serving = Serving(foodID: detail.food.id, label: Self.servingLabel, grams: servingG)
                    detail.servings.insert(serving, at: 0)
                    detail.food.defaultServingID = serving.id
                }
            } else if let managed {
                let removed = detail.servings.remove(at: managed)
                if detail.food.lastServingID == removed.id {
                    detail.food.lastServingID = nil
                    detail.food.lastAmount = nil
                }
            }
            let saved = try FoodRepository.save(db, detail: detail, barcodes: detail.barcodes, now: now)

            // Ingredients.
            let existing = try RecipeIngredient.filter(RecipeIngredient.Columns.recipeID == saved.food.id).fetchAll(db)
            var kept: [RecipeIngredient] = []
            for (index, var ingredient) in draft.ingredients.filter({ $0.grams > 0 }).enumerated() {
                ingredient.recipeID = saved.food.id
                ingredient.sortOrder = index
                if let old = existing.first(where: { $0.id == ingredient.id }) {
                    ingredient.createdAt = old.createdAt
                    ingredient.revision = old.revision
                    ingredient.deletedAt = nil
                    ingredient.stampUpdated(now)
                    try ingredient.update(db)
                } else {
                    ingredient.stampCreated(now)
                    try ingredient.insert(db)
                }
                kept.append(ingredient)
            }
            for var old in existing where old.deletedAt == nil && !kept.contains(where: { $0.id == old.id }) {
                old.stampDeleted(now)
                try old.update(db)
            }
            return Recipe(detail: saved, ingredients: kept)
        }
    }

    public func recipe(id: String) throws -> Recipe? {
        try database.reader.read { db in try Self.recipe(db, id: id) }
    }

    /// Active recipes by name.
    public func recipes() throws -> [Food] {
        try database.reader.read { db in
            try Food
                .filter(Food.Columns.deletedAt == nil && Food.Columns.source == FoodSource.recipe)
                .order(Food.Columns.name.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    /// Saves a copy of the recipe (new ids, same ingredient snapshots) named `name` (default "<name> copy").
    @discardableResult
    public func duplicate(id: String, name: String? = nil) throws -> Recipe {
        guard let source = try recipe(id: id) else { throw PersistenceError.notFound(id) }
        var draft = RecipeDraft(source)
        draft.id = nil
        draft.name = name ?? "\(source.food.name) copy"
        draft.ingredients = source.ingredients.map { ingredient in
            RecipeIngredient(
                foodID: ingredient.foodID,
                displayName: ingredient.displayName,
                grams: ingredient.grams,
                per100: ingredient.per100,
            )
        }
        return try save(draft)
    }

    static func recipe(_ db: Database, id: String) throws -> Recipe? {
        guard let detail = try FoodRepository.detail(db, id: id), detail.food.source == .recipe else { return nil }
        let ingredients = try RecipeIngredient
            .filter(RecipeIngredient.Columns.recipeID == id && RecipeIngredient.Columns.deletedAt == nil)
            .order(RecipeIngredient.Columns.sortOrder)
            .fetchAll(db)
        return Recipe(detail: detail, ingredients: ingredients)
    }
}
