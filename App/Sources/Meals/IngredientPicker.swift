import Core
import DesignSystem
import Persistence
import SwiftUI

/// Find a food for a meal — search your foods and the bundled index, scan a barcode, or create a food — then choose
/// how much of it goes in.
struct IngredientPicker: View {
    let onPick: (Food, Quantity, _ servingID: String?) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodSearchResult] = []
    @State private var suggestions: [Food] = []
    @State private var errorMessage: String?
    @State private var path: [FoodDetail] = []
    @State private var showScanner = false
    @State private var showCreate = false
    /// A food picked in the scanner, opened for its amount once the scanner has closed.
    @State private var scanned: FoodDetail?

    var body: some View {
        NavigationStack(path: $path) {
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
                        Button { pick(.food(food)) } label: { FoodRow(food, unit: environment.energyUnit) }
                            .buttonStyle(.plain)
                    }
                } else {
                    LocalSearchResults(
                        results: results,
                        emptyMessage: String(localized: "Create the food with its nutrition, or scan its barcode."),
                        unit: environment.energyUnit,
                    ) { pick($0) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Scan barcode", systemImage: "barcode.viewfinder") { showScanner = true }
                    Button("Create food", systemImage: "plus") { showCreate = true }
                }
            }
            .navigationDestination(for: FoodDetail.self) { detail in
                QuantitySheet(detail: detail, mode: .addToMeal { quantity, servingID in
                    onPick(detail.food, quantity, servingID)
                }) { dismiss() }
            }
            .sheet(isPresented: $showCreate) {
                FoodEditorView(initialName: query) { saved in path.append(saved) }
            }
            .fullScreenCover(isPresented: $showScanner, onDismiss: openScanned) {
                ScanView(onPick: { scanned = $0 }, onFinished: { showScanner = false })
            }
            .task {
                let recents = (try? environment.foods?.recents(slotID: nil)) ?? []
                let mine = (try? environment.foods?.customFoods()) ?? []
                suggestions = recents + mine.filter { food in !recents.contains { $0.id == food.id } }
            }
            .task(id: query) { await search() }
            .errorAlert($errorMessage)
        }
    }

    private func search() async {
        do {
            guard let found = try await LocalFoodSearch.results(for: query, in: environment) else { return }
            results = found
        } catch {
            results = []
        }
    }

    /// Opens the food's amount step.
    private func pick(_ result: FoodSearchResult) {
        guard let foods = environment.foods else { return }
        do {
            try path.append(foods.detail(for: result))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openScanned() {
        guard let detail = scanned else { return }
        scanned = nil
        path.append(detail)
    }
}
