import Core
import DesignSystem
import Persistence
import Scanner
import SwiftUI

/// Create / edit a custom food (backlog #9).
struct FoodEditorView: View {
    var editing: FoodDetail?
    var initialName: String = ""
    var barcode: String?
    var completing: Set<FoodEditorModel.RequiredNutrient>?
    var onSaved: (FoodDetail) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: FoodEditorModel?
    @State private var errorMessage: String?
    /// Barcodes on other foods, waiting for "move it here?".
    @State private var conflicts: [FoodEditorModel.BarcodeConflict] = []

    /// - Parameter completing: Complete-nutrition mode (see ``FoodEditorModel``): these nutrients start empty.
    init(
        editing: FoodDetail? = nil,
        initialName: String = "",
        barcode: String? = nil,
        completing: Set<FoodEditorModel.RequiredNutrient>? = nil,
        onSaved: @escaping (FoodDetail) -> Void = { _ in },
    ) {
        self.editing = editing
        self.initialName = initialName
        self.barcode = barcode
        self.completing = completing
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            if let model {
                FoodEditorForm(model: model, foods: environment.foods)
                    .navigationTitle(model.completing != nil ? "Complete nutrition" : model.isEditing ? "Edit food" : "New food")
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
                model = FoodEditorModel(
                    energyUnit: environment.energyUnit, editing: editing, initialName: initialName, barcode: barcode,
                    completing: completing,
                )
            }
        }
        .alert("Move barcode?", isPresented: Binding(get: { !conflicts.isEmpty }, set: {
            if !$0 {
                conflicts = []
            }
        }), presenting: conflicts) { presented in
            // Uses the presented conflicts: the binding's setter may already have cleared `conflicts`.
            Button("Move Here") {
                conflicts = []
                if let model {
                    commit(model, movingBarcodes: FoodEditorModel.moving(presented))
                }
            }
            Button("Cancel", role: .cancel) { conflicts = [] }
        } message: { presented in
            Text(FoodEditorModel.conflictMessage(presented) + "\n\nIt will be removed from the other food.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    /// Asks before taking a barcode from another food (saving would otherwise fail on it), then saves.
    private func save(_ model: FoodEditorModel) {
        guard let foods = environment.foods else { return }
        do {
            let found = try model.barcodeConflicts(in: foods)
            guard found.isEmpty else {
                conflicts = found
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        commit(model, movingBarcodes: [:])
    }

    private func commit(_ model: FoodEditorModel, movingBarcodes: [String: String]) {
        guard let foods = environment.foods else { return }
        do {
            guard let saved = try model.save(to: foods, movingBarcodes: movingBarcodes) else { return }
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
    let foods: FoodRepository?
    @State private var isScanning = false
    @State private var scanNotice: String?

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

            Section {
                ForEach($model.barcodeRows) { $row in
                    BarcodeRow(code: $row.code, owner: model.owner(of: row.code)) {
                        withAnimation { model.removeBarcode(id: row.id) }
                    }
                }
                .onDelete { model.removeBarcodes(atOffsets: $0) }
                Button("Scan barcode", systemImage: "barcode.viewfinder") {
                    scanNotice = nil
                    isScanning = true
                }
                Button("Type barcode", systemImage: "keyboard") { model.addBarcodeRow() }
            } header: {
                Text("Barcodes")
            } footer: {
                if let scanNotice {
                    Text(scanNotice)
                }
            }
            .task(id: model.barcodes) {
                if let foods {
                    model.refreshBarcodeOwners(in: foods)
                }
            }

            Section("Notes") {
                TextField("Source, details…", text: $model.notes, axis: .vertical)
            }

            if !model.validationErrors.isEmpty, !model.name.isEmpty || !model.energy.isEmpty {
                Section {
                    ForEach(model.validationErrors, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
        // Full screen, like the scanner of Add Food: the camera didn't work in a sheet over this sheet (#69).
        .fullScreenCover(isPresented: $isScanning) {
            BarcodeScanSheet { barcode in
                switch model.insertScanned(candidates: barcode.candidates) {
                case let .added(code):
                    scanNotice = "Added \(code)."
                    isScanning = false
                    return nil
                case let .duplicate(code):
                    scanNotice = "\(code) is already on this food."
                    isScanning = false
                    return nil
                case .invalid:
                    return "\(barcode.payload) isn't a product barcode (EAN / UPC). Try another code."
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

/// One barcode: the code (editable), a hint when another food carries it, and an explicit remove button besides
/// swipe-to-delete.
private struct BarcodeRow: View {
    @Binding var code: String
    let owner: String?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
            HStack {
                TextField("EAN / UPC", text: $code)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(code.isEmpty ? "Remove empty barcode" : "Remove barcode \(code)")
            }
            if let owner {
                Label("Also on '\(owner)' — saving asks to move it here", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The camera scanner (with its manual-entry fallback) for adding a barcode to a food. `onScan` returns a message
/// to show while scanning continues (an unusable code), or nil when the sheet is closed by the caller.
private struct BarcodeScanSheet: View {
    let onScan: (ScannedBarcode) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            BarcodeScannerView { barcode in
                notice = onScan(barcode)
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, NL.Spacing.l)
                        .padding(.vertical, NL.Spacing.s)
                        .glassEffect()
                        .padding(.top, NL.Spacing.m)
                        .padding(.horizontal, NL.Spacing.l)
                }
            }
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
