import Core
import DesignSystem
import Persistence
import SwiftUI

/// Choose an amount (base unit or a serving) with a live nutrient preview, then log or save (backlog #8).
struct QuantitySheet: View {
    enum Mode {
        /// Logs the food, or adds it to the meal plan when `planned`.
        case log(slotID: String, day: LocalDay, planned: Bool = false)
        case edit(DiaryEntry)
        /// Changes the amount of a planned food.
        case editPlanned(PlannedEntry)
    }

    let detail: FoodDetail
    let mode: Mode
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var unitChoice = "base" // "base" or a serving id
    @State private var amountText = ""
    @State private var slotID = ""
    @State private var isFavorite = false
    @State private var errorMessage: String?
    @FocusState private var amountFocused: Bool

    private var food: Food {
        detail.food
    }

    private var selectedServing: Serving? {
        detail.servings.first { $0.id == unitChoice }
    }

    private var quantity: Quantity? {
        Self.quantity(amountText: amountText, unitChoice: unitChoice, detail: detail)
    }

    /// The amount typed in `unitChoice` ("base" or a serving id) as a quantity; nil for invalid input, or for
    /// grams on a per-serving placeholder (its weight is a stand-in).
    static func quantity(amountText: String, unitChoice: String, detail: FoodDetail) -> Quantity? {
        guard let amount = Format.number(amountText), amount >= 0 else { return nil }
        if let serving = detail.servings.first(where: { $0.id == unitChoice }) {
            return .servings(count: amount, serving: serving.size)
        }
        return offersBaseUnit(detail) ? .base(amount) : nil
    }

    /// Whether grams/ml can be entered. Not for a per-serving placeholder: log it by servings only.
    static func offersBaseUnit(_ detail: FoodDetail) -> Bool {
        !detail.isPerServingPlaceholder
    }

    /// The quantity to prefill when logging: the food's suggestion, but never grams for a per-serving placeholder.
    static func initialLogQuantity(_ detail: FoodDetail) -> (quantity: Quantity, servingID: String?) {
        let suggested = detail.suggestedQuantity
        if !offersBaseUnit(detail), case .base = suggested,
           let serving = detail.servings.first(where: { $0.id == detail.food.defaultServingID })
        {
            return (.servings(count: 1, serving: serving.size), serving.id)
        }
        return (suggested, nil)
    }

    private var preview: Nutrients {
        quantity?.nutrients(per100: food.per100) ?? .zero
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: NL.Spacing.m) {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(NL.Typography.number)
                        .focused($amountFocused)
                        .frame(maxWidth: 120)
                        .accessibilityLabel("Amount")
                    Picker("Unit", selection: $unitChoice) {
                        // A per-serving placeholder's weight is a 100 g/ml stand-in: log it by servings only.
                        if Self.offersBaseUnit(detail) {
                            Text(food.baseUnit.symbol).tag("base")
                        }
                        ForEach(detail.servings) { serving in
                            if detail.isPerServingPlaceholder {
                                Text(serving.label).tag(serving.id)
                            } else {
                                Text("\(serving.label) (\(NutrientRow.format(serving.grams, unit: "g")) \(food.baseUnit.symbol))")
                                    .tag(serving.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if let quantity, selectedServing != nil, !detail.isPerServingPlaceholder {
                    Text("= \(NutrientRow.format(quantity.baseAmount, unit: "g")) \(food.baseUnit.symbol)")
                        .foregroundStyle(.secondary)
                }
                if case .log = mode {
                    Picker("Meal", selection: $slotID) {
                        ForEach(slots) { Text($0.name).tag($0.id) }
                    }
                }
            } header: {
                Text(food.brand.map { "\(food.name) · \($0)" } ?? food.name)
            }

            Section("Nutrition for this amount") {
                NutrientRow(
                    "Energy",
                    value: environment.energyUnit.display(preview.kcal),
                    unit: environment.energyUnit.symbol,
                    emphasized: true,
                )
                NutrientRow("Protein", value: preview.proteinG)
                NutrientRow("Carbohydrates", value: preview.carbsG)
                if let sugar = preview.sugarG {
                    NutrientRow("of which sugars", value: sugar, indent: true)
                }
                if let fiber = preview.fiberG {
                    NutrientRow("Fiber", value: fiber)
                }
                NutrientRow("Fat", value: preview.fatG)
                if let sat = preview.satFatG {
                    NutrientRow("of which saturated", value: sat, indent: true)
                }
                if let sodium = preview.sodiumMg {
                    NutrientRow("Sodium", value: sodium, unit: "mg")
                }
            }

            if food.dataQuality != .complete {
                Section {
                    Label("Some nutrients are missing for this food.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(isEditing ? (isPlanEdit ? "Edit planned amount" : "Edit amount") : (isPlanning ? "Plan food" : "Log food"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
            }
            // Stand-in foods for entries whose food was deleted are not in the database: no favorite toggle.
            if (try? environment.foods?.food(id: food.id)) != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button(isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: isFavorite ? "star.fill" : "star") {
                        toggleFavorite()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : (isPlanning ? "Plan" : "Log")) { commit() }
                    .disabled(quantity == nil || (quantity?.baseAmount ?? 0) <= 0)
            }
        }
        .onAppear(perform: prefill)
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var isEditing: Bool {
        switch mode {
        case .edit, .editPlanned: true
        case .log: false
        }
    }

    private var isPlanning: Bool {
        if case let .log(_, _, planned) = mode {
            return planned
        }
        return false
    }

    private var isPlanEdit: Bool {
        if case .editPlanned = mode {
            return true
        }
        return false
    }

    private var slots: [MealSlot] {
        (try? environment.diary?.mealSlots()) ?? []
    }

    private func prefill() {
        isFavorite = food.isFavorite
        switch mode {
        case let .log(slot, _, _):
            slotID = slot
            let initial = Self.initialLogQuantity(detail)
            apply(initial.quantity, servingID: initial.servingID)
        case let .edit(entry):
            restore(slotID: entry.mealSlotID, grams: entry.grams, servingLabel: entry.servingLabel)
        case let .editPlanned(entry):
            restore(slotID: entry.mealSlotID, grams: entry.grams, servingLabel: entry.servingLabel)
        }
        amountFocused = true
    }

    /// Restores "2 × slice" when the label matches a serving; otherwise shows the base amount.
    private func restore(slotID slot: String, grams: Double, servingLabel: String?) {
        slotID = slot
        if let label = servingLabel,
           let serving = detail.servings.first(where: { label.hasSuffix("× \($0.label)") }), serving.grams > 0
        {
            apply(.servings(count: grams / serving.grams, serving: serving.size), servingID: serving.id)
        } else {
            apply(.base(grams))
        }
    }

    private func apply(_ quantity: Quantity, servingID: String? = nil) {
        switch quantity {
        case let .base(amount):
            unitChoice = "base"
            amountText = Format.field(amount)
        case let .servings(count, serving):
            unitChoice = servingID ?? detail.servings.first { $0.label == serving.label && $0.grams == serving.amount }?.id ?? "base"
            amountText = Format.field(unitChoice == "base" ? count * serving.amount : count)
        }
    }

    private func toggleFavorite() {
        do {
            try environment.foods?.setFavorite(id: food.id, !isFavorite)
            isFavorite.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        guard let quantity, let diary = environment.diary else { return }
        do {
            switch mode {
            case let .log(_, day, planned):
                if planned {
                    guard let plan = environment.mealPlan else { return }
                    try plan.plan(food: food, quantity: quantity, slotID: slotID, day: day)
                } else {
                    try diary.log(food: food, quantity: quantity, servingID: selectedServing?.id, slotID: slotID, day: day)
                }
            case let .edit(entry):
                try diary.updateQuantity(entryID: entry.id, quantity: quantity)
            case let .editPlanned(entry):
                try environment.mealPlan?.updateQuantity(plannedID: entry.id, quantity: quantity)
            }
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
