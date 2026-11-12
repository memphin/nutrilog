import Core
import DesignSystem
import Persistence
import SwiftUI

/// Search your foods and the bundled index for a food to add to a meal.
struct IngredientPicker: View {
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
                            String(localized: "Search for a food"), systemImage: "magnifyingglass",
                            message: String(localized: "Your foods and the built-in food list are searched."),
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
                            String(localized: "No matches"),
                            systemImage: "magnifyingglass",
                            message: String(localized: "Create the food first in Foods, or scan it once."),
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
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let recents = (try? environment.foods?.recents(slotID: nil)) ?? []
                let mine = (try? environment.foods?.customFoods()) ?? []
                suggestions = recents + mine.filter { food in !recents.contains { $0.id == food.id } }
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
        results = (try? search.search(text)) ?? []
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
