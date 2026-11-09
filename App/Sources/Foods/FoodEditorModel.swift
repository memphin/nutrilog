import Core
import Foundation
import Observation
import Persistence

/// Form state for creating / editing a custom food (backlog #9, FR-23).
@MainActor
@Observable
final class FoodEditorModel {
    enum InputBasis: String, CaseIterable, Identifiable {
        case per100 = "Per 100 g/ml"
        case perServing = "Per serving"
        var id: String {
            rawValue
        }
    }

    struct ServingDraft: Identifiable, Equatable {
        var id: String = newID()
        var label: String = ""
        var amount: String = ""
    }

    // Identity
    var name = ""
    var nameLocal = ""
    var brand = ""
    var notes = ""
    var isLiquid = false

    // Nutrition input
    var basis: InputBasis = .per100
    var basisServingAmount = "" // g/ml of one serving when basis == .perServing
    var energy = "" // in the display energy unit
    var protein = ""
    var carbs = ""
    var fat = ""
    var fiber = ""
    var sugar = ""
    var satFat = ""
    var sodiumOrSalt = ""
    var entersSalt = true // EU labels show salt; US labels sodium

    var servings: [ServingDraft] = []
    var defaultServingID: String?
    var barcodes: [String] = []

    let energyUnit: EnergyUnit
    private(set) var original: FoodDetail?

    /// Nutrition fields as loaded from `original`. Fields still showing this text keep the stored value on
    /// save: the fields round to 2 decimals, and USDA / Open Food Facts values often have more.
    private struct LoadedFields {
        var energy, protein, carbs, fat, fiber, sugar, satFat, sodiumOrSalt: String
        var entersSalt: Bool
    }

    private var loaded: LoadedFields?

    init(energyUnit: EnergyUnit, editing detail: FoodDetail? = nil, initialName: String = "", barcode: String? = nil) {
        self.energyUnit = energyUnit
        original = detail
        name = initialName
        if let barcode {
            barcodes = [barcode]
        }
        if let detail {
            load(detail)
        }
    }

    var isEditing: Bool {
        original != nil
    }

    var unitSymbol: String {
        isLiquid ? "ml" : "g"
    }

    // MARK: Derived values

    /// Per-100 nutrients from the inputs, or nil when a required value is missing/invalid.
    var per100: Nutrients? {
        guard let kcalInput = Self.value(energy), let p = Self.value(protein), let c = Self.value(carbs), let f = Self.value(fat)
        else { return nil }
        let optionals = [fiber, sugar, satFat, sodiumOrSalt]
        guard optionals.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || Self.value($0) != nil }) else { return nil }
        let sodiumInput = Self.value(sodiumOrSalt)
        let entered = Nutrients(
            kcal: energyUnit.fromDisplay(kcalInput), proteinG: p, carbsG: c, fatG: f,
            fiberG: Self.value(fiber), sugarG: Self.value(sugar), satFatG: Self.value(satFat),
            sodiumMg: sodiumInput.map { entersSalt ? Salt.sodiumMg(fromSaltG: $0) : $0 },
        )
        switch basis {
        case .per100:
            return entered
        case .perServing:
            guard let grams = Self.value(basisServingAmount), grams > 0 else { return nil }
            return Nutrients.per100(fromServing: entered, servingGrams: grams)
        }
    }

    /// Problems that block saving.
    var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Enter a name.")
        }
        if basis == .perServing, (Self.value(basisServingAmount) ?? 0) <= 0 {
            errors.append("Enter the serving size.")
        }
        if per100 == nil {
            errors.append("Enter energy, protein, carbs and fat (numbers ≥ 0).")
        }
        for serving in servings where !serving.label.isEmpty || !serving.amount.isEmpty {
            if serving.label.trimmingCharacters(in: .whitespaces).isEmpty || (Self.value(serving.amount) ?? 0) <= 0 {
                errors.append("Each serving needs a name and an amount.")
                break
            }
        }
        for code in barcodes where !code.isEmpty && Barcode.normalize(code) == nil {
            errors.append("Barcode \(code) is not valid.")
        }
        return errors
    }

    /// Non-blocking warnings (backlog #9: plausibility check, don't block).
    var warnings: [String] {
        guard let n = per100 else { return [] }
        var result: [String] = []
        if n.hasImplausibleEnergy() {
            let estimate = Int(n.kcalFromMacros.rounded())
            result.append("Energy differs from protein/carbs/fat (≈ \(estimate) kcal per 100). Double-check the label.")
        }
        if n.proteinG + n.carbsG + n.fatG > 100.5 {
            result.append("Protein + carbs + fat exceed 100 g per 100 g.")
        }
        if let sugar = n.sugarG, sugar > n.carbsG + 0.05 {
            result.append("Sugars are higher than carbohydrates.")
        }
        if let sat = n.satFatG, sat > n.fatG + 0.05 {
            result.append("Saturated fat is higher than total fat.")
        }
        return result
    }

    var canSave: Bool {
        validationErrors.isEmpty
    }

    // MARK: Building the record

    func makeDetail() -> FoodDetail? {
        guard canSave, let per100 else { return nil }
        var food = original?.food ?? Food(name: "", per100: per100)
        food.name = name.trimmingCharacters(in: .whitespaces)
        food.nameLocal = Self.optional(nameLocal)
        food.brand = Self.optional(brand)
        food.notes = Self.optional(notes)
        food.isLiquid = isLiquid
        food.per100 = keepingUneditedValues(per100)
        // Editing a bundled / USDA / Open Food Facts food keeps its data-quality flag.
        food.dataQuality = original?.food.dataQuality ?? .complete
        let drafts = servings.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        let savedServings = drafts.map { draft in
            let old = original?.servings.first { $0.id == draft.id }
            var serving = old ?? Serving(id: draft.id, label: "", grams: 1)
            serving.label = draft.label.trimmingCharacters(in: .whitespaces)
            if let old, draft.amount == Format.field(old.grams) {
                serving.grams = old.grams // amount not edited: keep the unrounded value
            } else {
                serving.grams = Self.value(draft.amount) ?? 1
            }
            return serving
        }
        food.defaultServingID = savedServings.contains { $0.id == defaultServingID } ? defaultServingID : nil
        return FoodDetail(food: food, servings: savedServings, barcodes: barcodes.filter { !$0.isEmpty })
    }

    func addServing() {
        servings.append(ServingDraft())
    }

    // MARK: Helpers

    /// `entered` with every nutrient whose field the user left as loaded replaced by the stored value.
    private func keepingUneditedValues(_ entered: Nutrients) -> Nutrients {
        // Per-serving input reinterprets every field, so then all values are new.
        guard let stored = original?.food.per100, let loaded, basis == .per100 else { return entered }
        var result = entered
        if energy == loaded.energy {
            result.kcal = stored.kcal
        }
        if protein == loaded.protein {
            result.proteinG = stored.proteinG
        }
        if carbs == loaded.carbs {
            result.carbsG = stored.carbsG
        }
        if fat == loaded.fat {
            result.fatG = stored.fatG
        }
        if fiber == loaded.fiber {
            result.fiberG = stored.fiberG
        }
        if sugar == loaded.sugar {
            result.sugarG = stored.sugarG
        }
        if satFat == loaded.satFat {
            result.satFatG = stored.satFatG
        }
        if sodiumOrSalt == loaded.sodiumOrSalt, entersSalt == loaded.entersSalt {
            result.sodiumMg = stored.sodiumMg
        }
        return result
    }

    private func load(_ detail: FoodDetail) {
        let food = detail.food
        name = food.name
        nameLocal = food.nameLocal ?? ""
        brand = food.brand ?? ""
        notes = food.notes ?? ""
        isLiquid = food.isLiquid
        energy = Format.field(energyUnit.display(food.kcal100))
        protein = Format.field(food.proteinG100)
        carbs = Format.field(food.carbsG100)
        fat = Format.field(food.fatG100)
        fiber = Format.field(food.fiberG100)
        sugar = Format.field(food.sugarG100)
        satFat = Format.field(food.satFatG100)
        entersSalt = false
        sodiumOrSalt = Format.field(food.sodiumMg100)
        loaded = LoadedFields(
            energy: energy, protein: protein, carbs: carbs, fat: fat, fiber: fiber, sugar: sugar, satFat: satFat,
            sodiumOrSalt: sodiumOrSalt, entersSalt: entersSalt,
        )
        servings = detail.servings.map { ServingDraft(id: $0.id, label: $0.label, amount: Format.field($0.grams)) }
        defaultServingID = food.defaultServingID
        barcodes = detail.barcodes
    }

    static func value(_ text: String) -> Double? {
        guard let number = Format.number(text), number >= 0, number.isFinite else { return nil }
        return number
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
