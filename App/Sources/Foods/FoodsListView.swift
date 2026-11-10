import Core
import DesignSystem
import Persistence
import SwiftUI

/// "Foods" tab: your custom foods and favorites — create, edit, favorite, delete (with undo).
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
    @State private var showCreateRecipe = false
    @State private var editingRecipe: RecipeSelection?

    /// A recipe opened in the recipe editor.
    struct RecipeSelection: Identifiable {
        let id: String
    }

    var body: some View {
        List {
            if model.foods.isEmpty {
                EmptyStateView(
                    "No foods yet",
                    systemImage: "fork.knife",
                    message: "Create foods for things you eat often — local specialties, home recipes, packaged products.",
                )
                .listRowBackground(Color.clear)
            }
            ForEach(model.filtered) { food in
                Button {
                    if food.source == .recipe {
                        editingRecipe = RecipeSelection(id: food.id)
                    } else {
                        editing = model.detail(for: food)
                    }
                } label: {
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
        }
        .searchable(text: $model.query, prompt: "Filter my foods")
        .navigationTitle("My foods")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("New", systemImage: "plus") {
                    Button("New food", systemImage: "fork.knife") { showCreate = true }
                    Button("New recipe", systemImage: "frying.pan") { showCreateRecipe = true }
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
        .sheet(isPresented: $showCreateRecipe, onDismiss: reload) {
            RecipeEditorView()
        }
        .sheet(item: $editingRecipe, onDismiss: reload) { selection in
            // Duplicating opens the copy next.
            RecipeEditorView(recipeID: selection.id) { saved in
                if saved.id != selection.id {
                    Task { editingRecipe = RecipeSelection(id: saved.id) }
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
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
