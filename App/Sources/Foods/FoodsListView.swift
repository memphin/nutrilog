import Core
import DesignSystem
import Persistence
import SwiftUI

/// "Foods" tab: your custom foods and favorites — create, edit, favorite, delete.
struct FoodsListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var foods: [Food] = []
    @State private var query = ""
    @State private var editing: FoodDetail?
    @State private var showCreate = false
    @State private var errorMessage: String?

    private var filtered: [Food] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return foods }
        return foods.filter {
            $0.name.localizedStandardContains(text) || ($0.nameLocal?.localizedStandardContains(text) ?? false)
                || ($0.brand?.localizedStandardContains(text) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if foods.isEmpty {
                    EmptyStateView(
                        "No foods yet",
                        systemImage: "fork.knife",
                        message: "Create foods for things you eat often — local specialties, home recipes, packaged products.",
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(filtered) { food in
                    Button {
                        editing = try? environment.foods?.detail(id: food.id)
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
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(food) }
                    }
                    .swipeActions(edge: .leading) {
                        Button(food.isFavorite ? "Unfavorite" : "Favorite", systemImage: food.isFavorite ? "star.slash" : "star") {
                            toggleFavorite(food)
                        }
                        .tint(.yellow)
                    }
                }
            }
            .searchable(text: $query, prompt: "Filter my foods")
            .navigationTitle("My foods")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New food", systemImage: "plus") { showCreate = true }
                }
            }
            .task { reload() }
            .refreshable { reload() }
            .sheet(isPresented: $showCreate, onDismiss: reload) {
                FoodEditorView()
            }
            .sheet(item: $editing, onDismiss: reload) { detail in
                FoodEditorView(editing: detail)
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

    private func reload() {
        guard let repo = environment.foods else { return }
        do {
            // Custom foods, recipes and anything starred (e.g. a favorite USDA item).
            let mine = try repo.customFoods()
            let favorites = try repo.favorites().filter { fav in !mine.contains { $0.id == fav.id } }
            foods = (mine + favorites).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ food: Food) {
        do {
            try environment.foods?.softDelete(id: food.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleFavorite(_ food: Food) {
        do {
            try environment.foods?.setFavorite(id: food.id, !food.isFavorite)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension FoodDetail: @retroactive Identifiable {
    public var id: String {
        food.id
    }
}
