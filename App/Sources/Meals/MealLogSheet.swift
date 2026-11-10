import Core
import DesignSystem
import Persistence
import SwiftUI

/// A saved meal in the Add Food list.
struct MealRow: View {
    let meal: MealTemplateDetail
    let unit: EnergyUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(meal.template.name).foregroundStyle(.primary).lineLimit(2)
                Text(meal.items.map(\.food.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if meal.hasDeletedFoods {
                    Label("Contains a deleted food", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                Text(unit.format(meal.totals.kcal)).monospacedDigit().foregroundStyle(.primary)
                Text("\(meal.items.count) \(meal.items.count == 1 ? "food" : "foods")").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Editable copy of a saved meal's items for one logging.
struct MealLogDraft: Equatable {
    struct Line: Identifiable, Equatable {
        var item: MealTemplateDetail.Item
        var isIncluded = true
        var amountText: String

        var id: String {
            item.id
        }

        var grams: Double? {
            Format.number(amountText).flatMap { $0 > 0 ? $0 : nil }
        }

        var nutrients: Nutrients {
            guard isIncluded, let grams else { return .zero }
            return item.food.per100.scaled(toGrams: grams)
        }
    }

    var lines: [Line]

    init(_ meal: MealTemplateDetail) {
        lines = meal.items.map { Line(item: $0, amountText: Format.field($0.item.grams)) }
    }

    var totals: Nutrients {
        Nutrients.sum(lines.map(\.nutrients))
    }

    /// What will be logged; nil while an included line has no valid amount or nothing is included.
    var logItems: [DiaryRepository.LogItem]? {
        let included = lines.filter(\.isIncluded)
        guard !included.isEmpty else { return nil }
        var items: [DiaryRepository.LogItem] = []
        for line in included {
            guard let grams = line.grams else { return nil }
            items.append(DiaryRepository.LogItem(food: line.item.food, quantity: .base(grams)))
        }
        return items
    }
}

/// Logs a saved meal: every item with its amount, editable before confirming (FR-24, backlog #32).
struct MealLogSheet: View {
    let meal: MealTemplateDetail
    let target: AddTarget
    let onLogged: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealLogDraft
    @State private var slotID: String
    @State private var errorMessage: String?

    init(meal: MealTemplateDetail, target: AddTarget, onLogged: @escaping () -> Void) {
        self.meal = meal
        self.target = target
        self.onLogged = onLogged
        _draft = State(initialValue: MealLogDraft(meal))
        _slotID = State(initialValue: target.slotID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($draft.lines) { $line in
                        VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                            Toggle(isOn: $line.isIncluded) {
                                Text(line.item.food.name).lineLimit(2)
                            }
                            if line.isIncluded {
                                HStack {
                                    TextField("Amount", text: $line.amountText)
                                        .keyboardType(.decimalPad)
                                        .frame(maxWidth: 90)
                                        .accessibilityLabel("Amount of \(line.item.food.name)")
                                    Text(line.item.food.baseUnit.symbol).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(environment.energyUnit.format(line.nutrients.kcal)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            if line.item.isFoodDeleted {
                                Label(
                                    "This food was deleted. It can still be logged with its last values.",
                                    systemImage: "exclamationmark.triangle",
                                )
                                .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Foods")
                } footer: {
                    Text("Changes here apply to this logging only; the saved meal stays as it is.")
                }

                Section {
                    Picker("Meal", selection: $slotID) {
                        ForEach(slots) { Text($0.name).tag($0.id) }
                    }
                    NutrientRow(
                        "Energy", value: environment.energyUnit.display(draft.totals.kcal), unit: environment.energyUnit.symbol,
                        emphasized: true,
                    )
                    MacroLine(protein: draft.totals.proteinG, carbs: draft.totals.carbsG, fat: draft.totals.fatG)
                }
            }
            .navigationTitle(meal.template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") { log() }.disabled(draft.logItems == nil)
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var slots: [MealSlot] {
        (try? environment.diary?.mealSlots()) ?? []
    }

    private func log() {
        guard let items = draft.logItems, let meals = environment.meals else { return }
        do {
            try meals.log(templateID: meal.id, items: items, slotID: slotID, day: target.day)
            dismiss()
            onLogged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
