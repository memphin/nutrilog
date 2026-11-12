import Core
import DesignSystem
import Persistence
import SwiftUI

/// A meal opened in the meal editor (sheet item).
struct MealSelection: Identifiable {
    let id: String
}

/// Create or edit a saved meal: a name and its foods with amounts (FR-24, issue #68).
struct MealEditorView: View {
    /// The meal to edit; nil creates one.
    var mealID: String?
    var onSaved: (MealTemplateDetail) -> Void = { _ in }
    /// Called after the meal was deleted from the editor, with the meal as it was.
    var onDeleted: (MealTemplateDetail) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: MealEditorModel?
    @State private var original: MealTemplateDetail?
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    MealForm(model: model, unit: environment.energyUnit, showPicker: $showPicker) {
                        confirmDelete = true
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(mealID == nil ? "New meal" : "Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(model?.validationErrors.isEmpty != true)
                }
            }
            .sheet(isPresented: $showPicker) {
                IngredientPicker { food in model?.add(food) }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete meal", role: .destructive) { delete() }
            } message: {
                Text("Its foods and the diary entries logged from it stay as they are.")
            }
            .alert("Meal", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard model == nil else { return }
        guard let mealID else {
            model = MealEditorModel()
            return
        }
        do {
            guard let meal = try environment.meals?.detail(id: mealID), meal.template.deletedAt == nil else {
                errorMessage = String(localized: "This meal is no longer available.")
                model = MealEditorModel()
                return
            }
            original = meal
            model = MealEditorModel(meal: meal)
        } catch {
            errorMessage = error.localizedDescription
            model = MealEditorModel()
        }
    }

    private func save() {
        guard let model, let meals = environment.meals else { return }
        do {
            let saved = try model.save(to: meals)
            dismiss()
            onSaved(saved)
        } catch let PersistenceError.validation(message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let original else { return }
        do {
            try environment.meals?.softDelete(id: original.id)
            dismiss()
            onDeleted(original)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MealForm: View {
    @Bindable var model: MealEditorModel
    let unit: EnergyUnit
    @Binding var showPicker: Bool
    let delete: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.name)
            }

            Section {
                ForEach($model.rows) { $row in
                    VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                        HStack {
                            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                                Text(row.food.name).lineLimit(2)
                                Text(unit.format(row.nutrients.kcal))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            TextField("0", text: $row.amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                                .accessibilityLabel("Amount of \(row.food.name) in \(row.food.baseUnit.symbol)")
                            Text(row.food.baseUnit.symbol).foregroundStyle(.secondary)
                        }
                        if row.isFoodDeleted {
                            Label("This food was deleted. The meal keeps its last values.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .onDelete { model.remove(atOffsets: $0) }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                Button("Add food", systemImage: "plus") { showPicker = true }
            } header: {
                Text("Foods")
            } footer: {
                Text("A meal always uses the current values of its foods. Swipe to remove a food, hold and drag to reorder.")
            }

            if !model.rows.isEmpty {
                Section("Whole meal") {
                    NutrientRow(String(localized: "Energy"), value: unit.display(model.totals.kcal), unit: unit.symbol, emphasized: true)
                    MacroLine(protein: model.totals.proteinG, carbs: model.totals.carbsG, fat: model.totals.fatG)
                }
            }

            if !model.validationErrors.isEmpty {
                Section {
                    ForEach(model.validationErrors, id: \.self) { Text($0).foregroundStyle(.red).font(.footnote) }
                }
            }

            if !model.isNew {
                Section {
                    Button("Delete meal", systemImage: "trash", role: .destructive, action: delete)
                } footer: {
                    Text("Saving changes never alters what you already logged: diary entries keep their own values.")
                }
            }
        }
    }
}
