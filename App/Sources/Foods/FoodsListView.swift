import Core
import DesignSystem
import Persistence
import SwiftUI

/// "Foods" tab: your saved meals, custom foods and favorites — create, edit, favorite, delete (with undo).
struct FoodsListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: FoodsListModel?

    var body: some View {
        NavigationStack {
            if let model {
                FoodsListContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = FoodsListModel(environment: environment)
            }
        }
    }
}

private struct FoodsListContent: View {
    @Bindable var model: FoodsListModel
    @Environment(AppEnvironment.self) private var environment
    @State private var editing: FoodDetail?
    @State private var showCreate = false
    @State private var showCreateMeal = false
    @State private var editingMeal: MealSelection?
    @State private var savingSlot: MealSlot?
    @State private var mealName = ""

    var body: some View {
        List {
            if model.foods.isEmpty, model.meals.isEmpty {
                EmptyStateView(
                    String(localized: "No foods yet"),
                    systemImage: "fork.knife",
                    message: String(localized: """
                    Create foods for things you eat often — local specialties, home cooking, packaged products — and \
                    combine foods into meals.
                    """),
                )
                .listRowBackground(Color.clear)
            }
            if !model.filteredMeals.isEmpty {
                Section("Meals") {
                    ForEach(model.filteredMeals) { meal in
                        Button { editingMeal = MealSelection(id: meal.id) } label: {
                            MealRow(meal: meal, unit: environment.energyUnit)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(meal) }
                        }
                    }
                }
            }
            if !model.filtered.isEmpty {
                Section {
                    ForEach(model.filtered) { food in
                        foodRow(food)
                    }
                } header: {
                    if !model.meals.isEmpty {
                        Text("Foods")
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "Filter my foods")
        .navigationTitle("My foods")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("New", systemImage: "plus") {
                    Button("New food", systemImage: "fork.knife") { showCreate = true }
                    Button("New meal", systemImage: "takeoutbag.and.cup.and.straw") { showCreateMeal = true }
                    mealFromTodayMenu
                }
            }
        }
        .task { model.reload() }
        .refreshable { model.reload() }
        .onChange(of: environment.dataGeneration) { model.dataDidChangeExternally() }
        .undoToast(model.undo)
        .sheet(isPresented: $showCreate, onDismiss: reload) {
            FoodEditorView()
        }
        .sheet(item: $editing, onDismiss: reload) { detail in
            FoodEditorView(editing: detail)
        }
        .sheet(isPresented: $showCreateMeal, onDismiss: reload) {
            MealEditorView()
        }
        .sheet(item: $editingMeal, onDismiss: reload) { selection in
            MealEditorView(mealID: selection.id, onDeleted: { model.mealWasDeleted($0) })
        }
        .alert("Save as meal", isPresented: Binding(get: { savingSlot != nil }, set: {
            if !$0 {
                savingSlot = nil
            }
        })) {
            TextField("Name", text: $mealName)
            Button("Save") {
                if let slot = savingSlot {
                    model.saveMeal(from: slot, name: mealName)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the foods you logged today so you can log them all at once from Add food → Meals.")
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    /// Breakfast, lunch, dinner, snacks… as logged today, each one tap away from becoming a saved meal.
    private var mealFromTodayMenu: some View {
        Menu("Meal from today", systemImage: "calendar.badge.plus") {
            ForEach(model.todaySlots) { item in
                Button {
                    mealName = item.slot.displayName
                    savingSlot = item.slot
                } label: {
                    Text(item.slot.displayName)
                    Text(item.foodCount == 0 ? "Nothing logged" : "\(item.foodCount) foods")
                }
                .disabled(item.foodCount == 0)
            }
        }
    }

    /// Any food — a legacy recipe food included — opens in the ordinary food editor.
    private func foodRow(_ food: Food) -> some View {
        Button { editing = model.detail(for: food) } label: {
            HStack {
                FoodRow(
                    name: food.name,
                    brand: food.brand,
                    per100: food.per100,
                    source: food.source,
                    unit: environment.energyUnit,
                    isLiquid: food.isLiquid,
                )
                if food.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite")
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(food) }
        }
        .swipeActions(edge: .leading) {
            Button(food.isFavorite ? "Unfavorite" : "Favorite", systemImage: food.isFavorite ? "star.slash" : "star") {
                model.toggleFavorite(food)
            }
            .tint(.yellow)
        }
    }

    private func reload() {
        model.reload()
    }
}

extension FoodDetail: @retroactive Identifiable {
    public var id: String {
        food.id
    }
}
