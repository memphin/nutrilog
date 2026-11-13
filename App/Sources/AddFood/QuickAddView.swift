import Core
import DesignSystem
import Persistence
import SwiftUI

/// Calories (and optional macros) without a food (FR-5, backlog #10).
struct QuickAddView: View {
    enum Mode {
        /// Logs the calories, or adds them to the meal plan when `planned`.
        case create(slotID: String, day: LocalDay, planned: Bool = false)
        case edit(DiaryEntry)
    }

    let mode: Mode
    var onSaved: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var energy = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var slotID = ""
    @State private var errorMessage: String?

    private var nutrients: Nutrients? {
        Self.nutrients(energy: energy, protein: protein, carbs: carbs, fat: fat, unit: environment.energyUnit)
    }

    private var isValid: Bool {
        nutrients != nil
    }

    /// The typed values as nutrients; nil when the energy is missing, or any value is negative, not a number or above
    /// `EntryLimits` (the energy after converting from `unit` to kcal). Empty macros count as 0 g.
    static func nutrients(energy: String, protein: String, carbs: String, fat: String, unit: EnergyUnit) -> Nutrients? {
        guard let display = Format.number(energy), display >= 0 else { return nil }
        let kcal = unit.fromDisplay(display)
        guard kcal.isFinite, kcal <= EntryLimits.maxKcal else { return nil }
        var macros: [Double] = []
        for text in [protein, carbs, fat] {
            guard !text.isEmpty else {
                macros.append(0)
                continue
            }
            guard let grams = Format.number(text), grams >= 0, grams.isFinite, grams <= EntryLimits.maxMacroGrams else { return nil }
            macros.append(grams)
        }
        return Nutrients(kcal: kcal, proteinG: macros[0], carbsG: macros[1], fatG: macros[2])
    }

    /// Logs, plans or updates the quick add described by `mode`.
    static func save(mode: Mode, name: String, nutrients: Nutrients, slotID: String, environment: AppEnvironment) throws {
        guard let diary = environment.diary else { return }
        switch mode {
        case let .create(_, day, planned):
            if planned {
                guard let plan = environment.mealPlan else { return }
                try plan.planQuickAdd(name: name, nutrients: nutrients, slotID: slotID, day: day)
            } else {
                try diary.logQuickAdd(name: name, nutrients: nutrients, slotID: slotID, day: day)
            }
        case let .edit(entry):
            try diary.updateQuickAdd(entryID: entry.id, name: name, nutrients: nutrients)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    LabeledContent("Energy") {
                        HStack {
                            TextField("required", text: $energy)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(environment.energyUnit.symbol).foregroundStyle(.secondary)
                        }
                    }
                    if case .create = mode {
                        Picker("Meal", selection: $slotID) {
                            ForEach((try? environment.diary?.mealSlots()) ?? []) { Text($0.displayName).tag($0.id) }
                        }
                    }
                }
                Section("Macros (optional)") {
                    gramsField("Protein", $protein)
                    gramsField("Carbs", $carbs)
                    gramsField("Fat", $fat)
                }
            }
            .navigationTitle(isEditing ? "Edit quick add" : (isPlanning ? "Plan calories" : "Quick add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : (isPlanning ? "Plan" : "Add")) { save() }.disabled(!isValid)
                }
            }
            .onAppear(perform: prefill)
            .errorAlert($errorMessage)
        }
        .presentationDetents([.medium, .large])
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private var isPlanning: Bool {
        if case let .create(_, _, planned) = mode {
            return planned
        }
        return false
    }

    private func gramsField(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text("g").foregroundStyle(.secondary)
            }
        }
    }

    private func prefill() {
        switch mode {
        case let .create(slot, _, _):
            slotID = slot
        case let .edit(entry):
            name = QuickAddName.isDefault(entry.displayName) ? "" : entry.displayName
            energy = Format.field(environment.energyUnit.display(entry.kcal))
            protein = entry.proteinG > 0 ? Format.field(entry.proteinG) : ""
            carbs = entry.carbsG > 0 ? Format.field(entry.carbsG) : ""
            fat = entry.fatG > 0 ? Format.field(entry.fatG) : ""
        }
    }

    private func save() {
        guard let nutrients else { return }
        do {
            try Self.save(mode: mode, name: name, nutrients: nutrients, slotID: slotID, environment: environment)
            dismiss()
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
