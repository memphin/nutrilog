import Core
import DesignSystem
import Persistence
import SwiftUI

/// "+" on a meal slot: Recents / Favorites / My foods tabs plus unified search (backlog #8, FR-20, FR-22).
struct AddFoodView: View {
    let target: AddTarget
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case recents = "Recents", favorites = "Favorites", mine = "My foods"
        var id: String {
            rawValue
        }
    }

    @State private var tab: Tab = .recents
    @State private var query = ""
    @State private var lists = Lists()
    @State private var results: [FoodSearchResult] = []
    @State private var path: [FoodDetail] = []
    @State private var showCreate = false
    @State private var showQuickAdd = false
    @State private var errorMessage: String?

    struct Lists {
        var recents: [Food] = []
        var favorites: [Food] = []
        var mine: [Food] = []
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Picker("List", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    let foods = currentList
                    if foods.isEmpty {
                        EmptyStateView(emptyTitle, systemImage: "fork.knife", message: emptyMessage)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(foods) { food in
                        Button { open(food) } label: {
                            FoodRow(
                                name: food.name, brand: food.brand, per100: food.per100, source: food.source,
                                unit: environment.energyUnit, isLiquid: food.isLiquid,
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    if results.isEmpty {
                        EmptyStateView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            message: "Create the food to log it now and find it next time.",
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(results) { result in
                        Button { open(result) } label: {
                            FoodRow(
                                name: result.name, brand: result.brand, per100: result.per100, source: result.source,
                                unit: environment.energyUnit, isLiquid: false,
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle(slotName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Quick add", systemImage: "bolt") { showQuickAdd = true }
                    Button("Create food", systemImage: "plus") { showCreate = true }
                }
            }
            .navigationDestination(for: FoodDetail.self) { detail in
                QuantitySheet(detail: detail, mode: .log(slotID: target.slotID, day: target.day)) { dismiss() }
            }
            .task { reloadLists() }
            .task(id: query) { await runSearch() }
            .sheet(isPresented: $showCreate) {
                FoodEditorView(initialName: query) { saved in
                    reloadLists()
                    path.append(saved)
                }
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddView(mode: .create(slotID: target.slotID, day: target.day)) { dismiss() }
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

    private var slotName: String {
        let slots = (try? environment.diary?.mealSlots(includeInactive: true)) ?? []
        return "Add to \(slots.first { $0.id == target.slotID }?.name ?? "meal")"
    }

    private var currentList: [Food] {
        switch tab {
        case .recents: lists.recents
        case .favorites: lists.favorites
        case .mine: lists.mine
        }
    }

    private var emptyTitle: String {
        switch tab {
        case .recents: "Nothing logged yet"
        case .favorites: "No favorites"
        case .mine: "No custom foods"
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .recents: "Search above or create a food — it shows up here after you log it."
        case .favorites: "Tap the star on a food to keep it here."
        case .mine: "Foods you create appear here."
        }
    }

    private func reloadLists() {
        guard let foods = environment.foods else { return }
        do {
            lists = try Lists(
                recents: foods.recents(slotID: target.slotID),
                favorites: foods.favorites(),
                mine: foods.customFoods(),
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runSearch() async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let search = environment.search else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150)) // debounce typing
        guard !Task.isCancelled else { return }
        results = (try? search.search(text)) ?? []
    }

    private func open(_ food: Food) {
        guard let detail = try? environment.foods?.detail(id: food.id) else { return }
        path.append(detail)
    }

    private func open(_ result: FoodSearchResult) {
        switch result {
        case let .food(food):
            open(food)
        case let .bundled(item):
            do {
                guard let foods = environment.foods else { return }
                try open(foods.localCopy(of: item))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct FoodRow: View {
    let name: String
    let brand: String?
    let per100: Nutrients
    let source: FoodSource
    let unit: EnergyUnit
    let isLiquid: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: NL.Spacing.s) {
                    SourceBadge(source.badge)
                    if let brand, !brand.isEmpty {
                        Text(brand).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                Text(unit.format(per100.kcal)).monospacedDigit().foregroundStyle(.primary)
                Text(isLiquid ? "per 100 ml" : "per 100 g").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
