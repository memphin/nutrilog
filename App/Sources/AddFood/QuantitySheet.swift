import Core
import DesignSystem
import Persistence
import SwiftUI

/// Choose an amount (base unit or a serving) with a live nutrient preview, then log or save (backlog #8).
struct QuantitySheet: View {
    enum Mode {
        case log(slotID: String, day: LocalDay)
        case edit(DiaryEntry)
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
        guard let amount = Format.number(amountText), amount >= 0 else { return nil }
        if let serving = selectedServing {
            return .servings(count: amount, serving: serving.size)
        }
        return .base(amount)
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
                        Text(food.baseUnit.symbol).tag("base")
                        ForEach(detail.servings) { serving in
                            Text("\(serving.label) (\(NutrientRow.format(serving.grams, unit: "g")) \(food.baseUnit.symbol))")
                                .tag(serving.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if let quantity, selectedServing != nil {
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
        .navigationTitle(isEditing ? "Edit amount" : "Log food")
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
                Button(isEditing ? "Save" : "Log") { commit() }
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
        if case .edit = mode {
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
        case let .log(slot, _):
            slotID = slot
            apply(detail.suggestedQuantity)
        case let .edit(entry):
            slotID = entry.mealSlotID
            // Restore "2 × slice" when the label matches a serving; otherwise show the base amount.
            if let label = entry.servingLabel,
               let serving = detail.servings.first(where: { label.hasSuffix("× \($0.label)") }), serving.grams > 0
            {
                apply(.servings(count: entry.grams / serving.grams, serving: serving.size), servingID: serving.id)
            } else {
                apply(.base(entry.grams))
            }
        }
        amountFocused = true
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
            case let .log(_, day):
                try diary.log(food: food, quantity: quantity, servingID: selectedServing?.id, slotID: slotID, day: day)
            case let .edit(entry):
                try diary.updateQuantity(entryID: entry.id, quantity: quantity)
            }
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
