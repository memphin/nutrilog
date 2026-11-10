import Core
import DesignSystem
import Persistence
import SwiftUI

/// Create or edit a recipe: ingredients with amounts, cooked weight or servings, computed nutrition (FR-25).
struct RecipeEditorView: View {
    /// The recipe to edit; nil creates one.
    var recipeID: String?
    var onSaved: (Recipe) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: RecipeEditorModel?
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    RecipeForm(model: model, unit: environment.energyUnit, showPicker: $showPicker, duplicate: duplicate) {
                        confirmDelete = true
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(recipeID == nil ? "New recipe" : "Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(model?.validationErrors.isEmpty != true)
                }
            }
            .sheet(isPresented: $showPicker) {
                IngredientPicker(excludingRecipeID: recipeID) { food in model?.add(food) }
            }
            .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete recipe", role: .destructive) { delete() }
            } message: {
                Text("Diary entries logged from it stay as they are.")
            }
            .alert("Recipe", isPresented: Binding(get: { errorMessage != nil }, set: {
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
        guard let recipeID else {
            model = RecipeEditorModel()
            return
        }
        do {
            guard let recipe = try environment.recipes?.recipe(id: recipeID) else {
                errorMessage = "This recipe is no longer available."
                model = RecipeEditorModel()
                return
            }
            model = RecipeEditorModel(recipe: recipe)
        } catch {
            errorMessage = error.localizedDescription
            model = RecipeEditorModel()
        }
    }

    private func save() {
        guard let model, let recipes = environment.recipes else { return }
        do {
            let saved = try model.save(to: recipes)
            dismiss()
            onSaved(saved)
        } catch let PersistenceError.validation(message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate() {
        guard let recipeID, let recipes = environment.recipes else { return }
        do {
            let copy = try recipes.duplicate(id: recipeID)
            dismiss()
            onSaved(copy)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let recipeID else { return }
        do {
            try environment.foods?.softDelete(id: recipeID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecipeForm: View {
    @Bindable var model: RecipeEditorModel
    let unit: EnergyUnit
    @Binding var showPicker: Bool
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $model.name)
                TextField("Notes (optional)", text: $model.notes, axis: .vertical).lineLimit(1 ... 4)
            }

            Section {
                ForEach($model.rows) { $row in
                    HStack {
                        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                            Text(row.ingredient.displayName).lineLimit(2)
                            Text(unit.format(row.ingredient.per100.scaled(toGrams: row.grams ?? 0).kcal))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        TextField("0", text: $row.gramsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                            .accessibilityLabel("Amount of \(row.ingredient.displayName) in grams")
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                .onDelete { model.remove(atOffsets: $0) }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                Button("Add ingredient", systemImage: "plus") { showPicker = true }
                if !model.rows.isEmpty {
                    Menu {
                        Button("Half (× 0.5)") { model.scale(by: 0.5) }
                        Button("One and a half (× 1.5)") { model.scale(by: 1.5) }
                        Button("Double (× 2)") { model.scale(by: 2) }
                    } label: {
                        Label("Scale all amounts", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            } header: {
                Text("Ingredients")
            } footer: {
                Text("Each ingredient keeps the nutrition values it had when you added it. Swipe to remove.")
            }

            Section {
                LabeledContent("Cooked weight") { trailingField($model.cookedText, "g") }
                LabeledContent("Servings") { trailingField($model.servingsText, "") }
            } header: {
                Text("Yield")
            } footer: {
                Text(
                    "Weigh the finished dish for accurate values per 100 g — cooking changes the weight, not the "
                        + "calories. Leave it empty to use the raw weight. With a number of servings you can also log “1 serving”.",
                )
            }

            if let nutrition = model.nutrition {
                nutritionSection(nutrition)
            }

            if !model.validationErrors.isEmpty {
                Section {
                    ForEach(model.validationErrors, id: \.self) { Text($0).foregroundStyle(.red).font(.footnote) }
                }
            }

            if !model.isNew {
                Section {
                    Button("Duplicate recipe", systemImage: "plus.square.on.square", action: duplicate)
                    Button("Delete recipe", systemImage: "trash", role: .destructive, action: delete)
                } footer: {
                    Text("Saving changes never alters what you already logged: diary entries keep their own values.")
                }
            }
        }
    }

    private func nutritionSection(_ nutrition: RecipeNutrition) -> some View {
        Section("Nutrition") {
            LabeledContent("Raw weight", value: "\(NutrientRow.format(nutrition.rawWeightG, unit: "g")) g")
            LabeledContent("Whole recipe", value: unit.format(nutrition.total.kcal))
            NutrientRow("Per 100 g", value: unit.display(nutrition.per100.kcal), unit: unit.symbol, emphasized: true)
            MacroLine(protein: nutrition.per100.proteinG, carbs: nutrition.per100.carbsG, fat: nutrition.per100.fatG)
            if let serving = nutrition.perServing, let grams = nutrition.servingG {
                NutrientRow(
                    "Per serving (\(NutrientRow.format(grams, unit: "g")) g)",
                    value: unit.display(serving.kcal), unit: unit.symbol, emphasized: true,
                )
                MacroLine(protein: serving.proteinG, carbs: serving.carbsG, fat: serving.fatG)
            }
        }
    }

    private func trailingField(_ text: Binding<String>, _ unitLabel: String) -> some View {
        HStack {
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            if !unitLabel.isEmpty {
                Text(unitLabel).foregroundStyle(.secondary)
            }
        }
    }
}

/// Search your foods and the bundled index for a recipe ingredient.
struct IngredientPicker: View {
    /// A recipe can't contain itself.
    let excludingRecipeID: String?
    let onPick: (Food) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodSearchResult] = []
    @State private var suggestions: [Food] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if suggestions.isEmpty {
                        EmptyStateView(
                            "Search for an ingredient", systemImage: "magnifyingglass",
                            message: "Your foods and the built-in food list are searched.",
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(suggestions) { food in
                        Button { pick(food) } label: { row(food.name, food.brand, food.per100, food.source, food.isLiquid) }
                            .buttonStyle(.plain)
                    }
                } else {
                    if results.isEmpty {
                        EmptyStateView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            message: "Create the food first in Foods, or scan it once.",
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(results) { result in
                        Button { pick(result) } label: { row(result.name, result.brand, result.per100, result.source, result.isLiquid) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Add ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let recents = (try? environment.foods?.recents(slotID: nil)) ?? []
                let mine = (try? environment.foods?.customFoods()) ?? []
                suggestions = (recents + mine.filter { food in !recents.contains { $0.id == food.id } })
                    .filter { $0.id != excludingRecipeID }
            }
            .task(id: query) { await search() }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func search() async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let search = environment.search else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        results = ((try? search.search(text)) ?? []).filter { result in
            if case let .food(food) = result {
                return food.id != excludingRecipeID
            }
            return true
        }
    }

    private func row(_ name: String, _ brand: String?, _ per100: Nutrients, _ source: FoodSource, _ isLiquid: Bool) -> some View {
        FoodRow(name: name, brand: brand, per100: per100, source: source, unit: environment.energyUnit, isLiquid: isLiquid)
    }

    private func pick(_ food: Food) {
        onPick(food)
        dismiss()
    }

    private func pick(_ result: FoodSearchResult) {
        switch result {
        case let .food(food):
            pick(food)
        case let .bundled(item):
            do {
                guard let foods = environment.foods else { return }
                try pick(foods.localCopy(of: item))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
