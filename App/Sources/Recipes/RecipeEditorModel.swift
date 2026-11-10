import Core
import Foundation
import Observation
import Persistence

/// State of the recipe editor (FR-25, backlog #31).
@MainActor
@Observable
final class RecipeEditorModel {
    struct Row: Identifiable, Equatable {
        var ingredient: RecipeIngredient
        var gramsText: String

        var id: String {
            ingredient.id
        }

        var grams: Double? {
            Format.number(gramsText).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    var name = ""
    var notes = ""
    var rows: [Row] = []
    var cookedText = ""
    var servingsText = ""
    /// nil for a new recipe.
    private(set) var recipeID: String?

    init(recipe: Recipe? = nil) {
        guard let recipe else { return }
        recipeID = recipe.id
        name = recipe.food.name
        notes = recipe.food.notes ?? ""
        rows = recipe.ingredients.map { Row(ingredient: $0, gramsText: Format.field($0.grams)) }
        cookedText = Format.field(recipe.food.cookedWeightG)
        servingsText = Format.field(recipe.food.servingsCount)
    }

    var isNew: Bool {
        recipeID == nil
    }

    // MARK: Ingredients

    /// Adds `food` with a snapshot of its current values. Its last logged amount is a good first guess.
    func add(_ food: Food) {
        let grams = food.lastServingID == nil ? (food.lastAmount ?? 100) : 100
        rows.append(Row(ingredient: RecipeIngredient(food: food, grams: grams), gramsText: Format.field(grams)))
    }

    func remove(atOffsets offsets: IndexSet) {
        rows.remove(atOffsets: offsets)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
    }

    /// "Re-cook" a batch of a different size: scales every amount, and the cooked weight with them.
    func scale(by factor: Double) {
        for index in rows.indices {
            if let grams = rows[index].grams {
                rows[index].gramsText = Format.field(grams * factor)
            }
        }
        if let cooked = Format.number(cookedText), cooked > 0 {
            cookedText = Format.field(cooked * factor)
        }
    }

    // MARK: Result

    var draft: RecipeDraft {
        RecipeDraft(
            id: recipeID, name: name, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: rows.compactMap { row in
                guard let grams = row.grams else { return nil }
                var ingredient = row.ingredient
                ingredient.grams = grams
                return ingredient
            },
            cookedWeightG: Format.number(cookedText), servingsCount: Format.number(servingsText),
        )
    }

    var nutrition: RecipeNutrition? {
        draft.nutrition
    }

    var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give the recipe a name.")
        }
        if rows.isEmpty {
            errors.append("Add at least one ingredient.")
        } else if rows.contains(where: { $0.grams == nil }) {
            errors.append("Every ingredient needs an amount greater than zero.")
        }
        if !cookedText.trimmingCharacters(in: .whitespaces).isEmpty, (Format.number(cookedText) ?? 0) <= 0 {
            errors.append("The cooked weight must be a number greater than zero (or empty).")
        }
        if !servingsText.trimmingCharacters(in: .whitespaces).isEmpty, (Format.number(servingsText) ?? 0) <= 0 {
            errors.append("Servings must be a number greater than zero (or empty).")
        }
        return errors
    }

    /// Saves; returns the stored recipe.
    func save(to recipes: RecipeRepository) throws -> Recipe {
        let saved = try recipes.save(draft)
        recipeID = saved.id
        return saved
    }
}
