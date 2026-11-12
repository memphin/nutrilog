import Core
import Foundation
import Observation
import Persistence

/// State and actions for the "Foods" tab: saved meals, custom foods and favorites, with undoable delete.
@MainActor
@Observable
final class FoodsListModel {
    private(set) var foods: [Food] = []
    /// Saved meals, most used first.
    private(set) var meals: [MealTemplateDetail] = []
    /// Today's meal slots with how many foods each holds, for "Meal from today".
    private(set) var todaySlots: [TodaySlot] = []
    var query = ""
    var errorMessage: String?

    struct TodaySlot: Identifiable, Hashable {
        let slot: MealSlot
        /// Food entries that can go into a saved meal (quick-adds have no food).
        let foodCount: Int

        var id: String {
            slot.id
        }
    }

    let undo = UndoCenter()

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var filtered: [Food] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return foods }
        return foods.filter {
            $0.name.localizedStandardContains(text) || ($0.nameLocal?.localizedStandardContains(text) ?? false)
                || ($0.brand?.localizedStandardContains(text) ?? false)
        }
    }

    /// Meals whose name or one of whose foods matches the filter.
    var filteredMeals: [MealTemplateDetail] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return meals }
        return meals.filter { meal in
            meal.template.name.localizedStandardContains(text) || meal.items.contains { $0.food.name.localizedStandardContains(text) }
        }
    }

    func reload() {
        guard let repo = environment.foods else { return }
        do {
            meals = try environment.meals?.templates() ?? []
            // Custom foods and anything starred (e.g. a favorite USDA item).
            let mine = try repo.customFoods()
            let favorites = try repo.favorites().filter { fav in !mine.contains { $0.id == fav.id } }
            foods = (mine + favorites).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            todaySlots = try (environment.diary?.diary(for: environment.today).sections ?? []).map { section in
                TodaySlot(
                    slot: section.slot,
                    foodCount: section.entries.count(where: { !$0.isQuickAdd && $0.foodID != nil && $0.grams > 0 }),
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The full record for the editor, or nil (with an error shown) when it can't be read.
    func detail(for food: Food) -> FoodDetail? {
        do {
            guard let detail = try environment.foods?.detail(id: food.id) else {
                errorMessage = String(localized: "\(food.name) is no longer available.")
                reload()
                return nil
            }
            return detail
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Soft-deletes the food and offers undo, which saves the record as it was before the delete.
    func delete(_ food: Food) {
        guard let repo = environment.foods else { return }
        do {
            guard let before = try repo.detail(id: food.id) else {
                reload()
                return
            }
            try repo.softDelete(id: food.id)
            reload()
            let generation = environment.dataGeneration
            undo.offer(String(localized: "Deleted \(food.name)")) { [weak self] in
                guard let self, environment.dataGeneration == generation else { return }
                restore(before)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves the foods logged today in `slot` as a meal named `name` (the slot's name when empty).
    func saveMeal(from slot: MealSlot, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.meals?.createFromDiary(
                day: environment.today,
                slotID: slot.id,
                name: trimmed.isEmpty ? slot.displayName : trimmed,
            )
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Soft-deletes the meal and offers undo.
    func delete(_ meal: MealTemplateDetail) {
        do {
            try environment.meals?.softDelete(id: meal.id)
            mealWasDeleted(meal)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads and offers undo for a meal that was just deleted (here or in the meal editor).
    func mealWasDeleted(_ meal: MealTemplateDetail) {
        reload()
        let generation = environment.dataGeneration
        undo.offer(String(localized: "Deleted \(meal.template.name)")) { [weak self] in
            guard let self, environment.dataGeneration == generation else { return }
            do {
                try environment.meals?.restore(id: meal.id)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleFavorite(_ food: Food) {
        do {
            try environment.foods?.setFavorite(id: food.id, !food.isFavorite)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clears a pending undo and reloads when the data changed underneath (JSON import).
    func dataDidChangeExternally() {
        undo.dismiss()
        reload()
    }

    private func restore(_ detail: FoodDetail) {
        do {
            try environment.foods?.save(detail) // the saved copy has no `deletedAt`, so this undeletes it
            reload()
        } catch let PersistenceError.barcodeInUse(code, _) {
            errorMessage = String(localized: "Couldn't restore \(detail.food.name): barcode \(code) now belongs to another food.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
