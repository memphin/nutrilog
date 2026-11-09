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
                    editing = model.detail(for: food)
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
                Button("New food", systemImage: "plus") { showCreate = true }
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
