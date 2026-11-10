import Core
import Foundation
import Observation
import Persistence

/// State of the meal editor: a name and a list of foods with amounts (FR-24, issue #68).
@MainActor
@Observable
final class MealEditorModel {
    struct Row: Identifiable, Equatable {
        /// Stable while editing; not stored.
        let id: String
        var food: Food
        /// Amount in the food's base unit (g or ml).
        var amountText: String
        /// The serving the saved item was logged with; kept only while its amount is unchanged.
        fileprivate var saved: (grams: Double, servingID: String?)?

        init(food: Food, amount: Double, servingID: String? = nil, isSaved: Bool = false) {
            id = UUID().uuidString
            self.food = food
            amountText = Format.field(amount)
            saved = isSaved ? (amount, servingID) : nil
        }

        var amount: Double? {
            Format.number(amountText).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        }

        /// Nutrients of the amount at the food's current values; zero while the amount is invalid.
        var nutrients: Nutrients {
            guard let amount else { return .zero }
            return food.per100.scaled(toGrams: amount)
        }

        var isFoodDeleted: Bool {
            food.deletedAt != nil
        }

        fileprivate var item: MealTemplateRepository.NewItem? {
            guard let amount else { return nil }
            // The text is rounded for display: an untouched amount saves exactly as it was.
            if let saved, amountText == Format.field(saved.grams) {
                return .init(foodID: food.id, grams: saved.grams, servingID: saved.servingID)
            }
            return .init(foodID: food.id, grams: amount)
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id && lhs.food == rhs.food && lhs.amountText == rhs.amountText
        }
    }

    var name = ""
    var rows: [Row] = []
    /// nil for a new meal.
    private(set) var mealID: String?
    private var savedName = ""
    private var savedItems: [MealTemplateRepository.NewItem] = []

    init(meal: MealTemplateDetail? = nil) {
        guard let meal else { return }
        mealID = meal.id
        name = meal.template.name
        rows = meal.items.map { Row(food: $0.food, amount: $0.item.grams, servingID: $0.item.servingID, isSaved: true) }
        savedName = name
        savedItems = rows.compactMap(\.item)
    }

    var isNew: Bool {
        mealID == nil
    }

    // MARK: Ingredients

    /// Adds `food`. Its last logged amount (when logged in g/ml) is a good first guess.
    func add(_ food: Food) {
        let amount = food.lastServingID == nil ? (food.lastAmount ?? 100) : 100
        rows.append(Row(food: food, amount: amount > 0 ? amount : 100))
    }

    func remove(atOffsets offsets: IndexSet) {
        rows.remove(atOffsets: offsets)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Result

    /// Totals of the whole meal at the foods' current values.
    var totals: Nutrients {
        Nutrients.sum(rows.map(\.nutrients))
    }

    /// What will be saved; nil while a row has no valid amount.
    var items: [MealTemplateRepository.NewItem]? {
        var result: [MealTemplateRepository.NewItem] = []
        for row in rows {
            guard let item = row.item else { return nil }
            result.append(item)
        }
        return result
    }

    var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give the meal a name.")
        }
        if rows.isEmpty {
            errors.append("Add at least one food.")
        } else if items == nil {
            errors.append("Every food needs an amount greater than zero.")
        }
        return errors
    }

    /// Whether saving would change anything.
    var hasChanges: Bool {
        isNew || name.trimmingCharacters(in: .whitespacesAndNewlines) != savedName || items != savedItems
    }

    /// Saves (creates the meal, or renames it and replaces its foods); returns the stored meal.
    @discardableResult
    func save(to meals: MealTemplateRepository) throws -> MealTemplateDetail {
        guard let items, !items.isEmpty else { throw PersistenceError.validation("Every food needs an amount greater than zero.") }
        let id: String
        if let mealID {
            try meals.rename(id: mealID, to: name)
            if items != savedItems {
                try meals.setItems(id: mealID, items: items)
            }
            id = mealID
        } else {
            id = try meals.create(name: name, items: items).id
        }
        guard let stored = try meals.detail(id: id) else { throw PersistenceError.notFound(id) }
        mealID = id
        savedName = stored.template.name
        savedItems = items
        return stored
    }
}
