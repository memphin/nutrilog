import Core
import DesignSystem
import Persistence
import SwiftUI

/// Calories (and optional macros) without a food (FR-5, backlog #10).
struct QuickAddView: View {
    enum Mode {
        case create(slotID: String, day: LocalDay)
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

    private var energyValue: Double? {
        Format.number(energy).flatMap { $0 >= 0 ? environment.energyUnit.fromDisplay($0) : nil }
    }

    private var isValid: Bool {
        guard energyValue != nil else { return false }
        return [protein, carbs, fat].allSatisfy { $0.isEmpty || (Format.number($0) ?? -1) >= 0 }
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
                            ForEach((try? environment.diary?.mealSlots()) ?? []) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section("Macros (optional)") {
                    gramsField("Protein", $protein)
                    gramsField("Carbs", $carbs)
                    gramsField("Fat", $fat)
                }
            }
            .navigationTitle(isEditing ? "Edit quick add" : "Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { save() }.disabled(!isValid)
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
        .presentationDetents([.medium, .large])
    }

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    private func gramsField(_ title: String, _ text: Binding<String>) -> some View {
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
        case let .create(slot, _):
            slotID = slot
        case let .edit(entry):
            name = entry.displayName == "Quick add" ? "" : entry.displayName
            energy = Format.field(environment.energyUnit.display(entry.kcal))
            protein = entry.proteinG > 0 ? Format.field(entry.proteinG) : ""
            carbs = entry.carbsG > 0 ? Format.field(entry.carbsG) : ""
            fat = entry.fatG > 0 ? Format.field(entry.fatG) : ""
        }
    }

    private func save() {
        guard let kcal = energyValue, let diary = environment.diary else { return }
        let nutrients = Nutrients(
            kcal: kcal,
            proteinG: Format.number(protein) ?? 0,
            carbsG: Format.number(carbs) ?? 0,
            fatG: Format.number(fat) ?? 0,
        )
        do {
            switch mode {
            case let .create(_, day):
                try diary.logQuickAdd(name: name, nutrients: nutrients, slotID: slotID, day: day)
            case let .edit(entry):
                try diary.updateQuickAdd(entryID: entry.id, name: name, nutrients: nutrients)
            }
            dismiss()
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
