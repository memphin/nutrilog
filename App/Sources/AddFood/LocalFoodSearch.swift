import Core
import DesignSystem
import Persistence
import SwiftUI

/// The local food search shared by Add food and the meal editor's ingredient picker: own foods and the bundled
/// index, searched after a short pause in typing.
enum LocalFoodSearch {
    /// The hits for `query`: none for a blank query, nil when typing went on (the task was cancelled).
    @MainActor
    static func results(for query: String, in environment: AppEnvironment) async throws -> [FoodSearchResult]? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let search = environment.search else { return [] }
        try? await Task.sleep(for: .milliseconds(150)) // debounce typing
        guard !Task.isCancelled else { return nil }
        return try search.search(query)
    }
}

/// A food that was deleted since it was listed.
struct FoodNoLongerAvailable: LocalizedError {
    let name: String

    var errorDescription: String? {
        String(localized: "\(name) is no longer available.")
    }
}

extension FoodRepository {
    /// The stored food of a list row or search hit, to open for its amount: a bundled food is copied into My foods
    /// first. Throws ``FoodNoLongerAvailable`` for a food deleted since.
    func detail(for result: FoodSearchResult) throws -> FoodDetail {
        let food = switch result {
        case let .food(food): food
        case let .bundled(item): try localCopy(of: item)
        }
        guard let detail = try detail(id: food.id) else { throw FoodNoLongerAvailable(name: food.name) }
        return detail
    }
}

/// The local search hits as rows, with "No matches" when there are none.
struct LocalSearchResults: View {
    let results: [FoodSearchResult]
    /// False while the search failed, so "No matches" isn't claimed for a search that didn't run.
    var showsEmptyState = true
    let emptyMessage: String
    let unit: EnergyUnit
    let onPick: (FoodSearchResult) -> Void

    var body: some View {
        if results.isEmpty, showsEmptyState {
            EmptyStateView(String(localized: "No matches"), systemImage: "magnifyingglass", message: emptyMessage)
                .listRowBackground(Color.clear)
        }
        ForEach(results) { result in
            Button { onPick(result) } label: { FoodRow(result, unit: unit) }
                .buttonStyle(.plain)
        }
    }
}
