import Core
import DesignSystem
import Persistence
import SwiftUI

/// Create / edit a custom food (backlog #9).
struct FoodEditorView: View {
    var editing: FoodDetail?
    var initialName: String = ""
    var barcode: String?
    var onSaved: (FoodDetail) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: FoodEditorModel?
    @State private var errorMessage: String?

    init(editing: FoodDetail? = nil, initialName: String = "", barcode: String? = nil, onSaved: @escaping (FoodDetail) -> Void = { _ in }) {
        self.editing = editing
        self.initialName = initialName
        self.barcode = barcode
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            if let model {
                FoodEditorForm(model: model)
                    .navigationTitle(model.isEditing ? "Edit food" : "New food")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { save(model) }.disabled(!model.canSave)
                        }
                    }
            }
        }
        .onAppear {
            if model == nil {
                model = FoodEditorModel(energyUnit: environment.energyUnit, editing: editing, initialName: initialName, barcode: barcode)
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save(_ model: FoodEditorModel) {
        guard let detail = model.makeDetail(), let foods = environment.foods else { return }
        do {
            let saved = try foods.save(detail)
            dismiss()
            onSaved(saved)
        } catch let PersistenceError.barcodeInUse(code, foodID) {
            let owner = (try? foods.food(id: foodID))?.name ?? "another food"
            errorMessage = "Barcode \(code) already belongs to \(owner)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FoodEditorForm: View {
    @Bindable var model: FoodEditorModel

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.name)
                TextField("Local name (e.g. Croatian)", text: $model.nameLocal)
                TextField("Brand", text: $model.brand)
                Toggle("Liquid (measured in ml)", isOn: $model.isLiquid)
            }

            Section {
                Picker("Values are", selection: $model.basis) {
                    ForEach(FoodEditorModel.InputBasis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.basis == .perServing {
                    numberField("Serving size", $model.basisServingAmount, unit: model.unitSymbol)
                }
                numberField("Energy", $model.energy, unit: model.energyUnit.symbol)
                numberField("Protein", $model.protein, unit: "g")
                numberField("Carbohydrates", $model.carbs, unit: "g")
                numberField("of which sugars", $model.sugar, unit: "g", optional: true, indent: true)
                numberField("Fat", $model.fat, unit: "g")
                numberField("of which saturated", $model.satFat, unit: "g", optional: true, indent: true)
                numberField("Fiber", $model.fiber, unit: "g", optional: true)
                Picker("Label shows", selection: $model.entersSalt) {
                    Text("Salt (g)").tag(true)
                    Text("Sodium (mg)").tag(false)
                }
                numberField(model.entersSalt ? "Salt" : "Sodium", $model.sodiumOrSalt, unit: model.entersSalt ? "g" : "mg", optional: true)
            } header: {
                Text("Nutrition")
            } footer: {
                Text(model.basis == .per100
                    ? "Copy the values from the label's per 100 \(model.unitSymbol) column."
                    : "Values are converted to per 100 \(model.unitSymbol) when saved.")
            }

            if !model.warnings.isEmpty {
                Section {
                    ForEach(model.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                ForEach($model.servings) { $serving in
                    HStack {
                        TextField("e.g. slice", text: $serving.label)
                        TextField("amount", text: $serving.amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text(model.unitSymbol).foregroundStyle(.secondary)
                    }
                }
                .onDelete { model.servings.remove(atOffsets: $0) }
                Button("Add serving", systemImage: "plus") { model.addServing() }
                if model.servings.contains(where: { !$0.label.isEmpty }) {
                    Picker("Default", selection: $model.defaultServingID) {
                        Text("None (\(model.unitSymbol))").tag(String?.none)
                        ForEach(model.servings.filter { !$0.label.isEmpty }) { Text($0.label).tag(String?.some($0.id)) }
                    }
                }
            } header: {
                Text("Servings")
            } footer: {
                Text("Named portions like \"1 slice = 25 g\" make logging faster.")
            }

            Section("Barcodes") {
                ForEach(model.barcodes.indices, id: \.self) { index in
                    TextField("EAN / UPC", text: $model.barcodes[index])
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                }
                .onDelete { model.barcodes.remove(atOffsets: $0) }
                Button("Add barcode", systemImage: "barcode") { model.barcodes.append("") }
            }

            Section("Notes") {
                TextField("Source, recipe details…", text: $model.notes, axis: .vertical)
            }

            if !model.validationErrors.isEmpty, !model.name.isEmpty || !model.energy.isEmpty {
                Section {
                    ForEach(model.validationErrors, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
    }

    private func numberField(
        _ title: String,
        _ text: Binding<String>,
        unit: String,
        optional: Bool = false,
        indent: Bool = false,
    ) -> some View {
        LabeledContent {
            HStack {
                TextField(optional ? "optional" : "required", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .leading)
            }
        } label: {
            Text(title)
                .padding(.leading, indent ? NL.Spacing.l : 0)
                .foregroundStyle(indent ? .secondary : .primary)
        }
    }
}
