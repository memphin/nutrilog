import Core
import DesignSystem
import Persistence
import SwiftUI

/// "+" on a meal slot: Recents / Favorites / My foods / Meals tabs plus unified search (backlog #8, #32, FR-20, FR-22).
struct AddFoodView: View {
    let target: AddTarget
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case recents = "Recents", favorites = "Favorites", mine = "My foods", meals = "Meals"
        var id: String {
            rawValue
        }
    }

    @State private var tab: Tab = .recents
    @State private var query = ""
    @State private var lists = Lists()
    @State private var results: [FoodSearchResult] = []
    @State private var searchFailed = false
    @State private var path: [FoodDetail] = []
    @State private var showCreate = false
    @State private var showQuickAdd = false
    @State private var showScanner = false
    @State private var errorMessage: String?
    @State private var scope: SearchScope = .local
    @State private var online = OnlineSearchModel()
    @State private var servingPrompt: PendingServingWeight?
    @State private var meals: [MealTemplateDetail] = []
    @State private var loggingMeal: MealTemplateDetail?
    @State private var renamingMeal: MealTemplateDetail?
    @State private var editingMeal: MealSelection?
    @State private var mealName = ""

    /// Where a typed search looks: this iPhone (own foods + bundled index) or online (OFF + USDA, backlog #22).
    enum SearchScope: String, CaseIterable, Identifiable {
        case local = "On this iPhone", online = "Online"
        var id: String {
            rawValue
        }
    }

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
                    if tab == .meals ? meals.isEmpty : foods.isEmpty {
                        EmptyStateView(emptyTitle, systemImage: "fork.knife", message: emptyMessage)
                            .listRowBackground(Color.clear)
                    }
                    if tab == .meals {
                        ForEach(meals) { meal in
                            Button { loggingMeal = meal } label: {
                                MealRow(meal: meal, unit: environment.energyUnit)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteMeal(meal) }
                                Button("Edit", systemImage: "pencil") { editingMeal = MealSelection(id: meal.id) }.tint(.blue)
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editingMeal = MealSelection(id: meal.id) }
                                Button("Rename", systemImage: "character.cursor.ibeam") {
                                    mealName = meal.template.name
                                    renamingMeal = meal
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteMeal(meal) }
                            }
                        }
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
                    Picker("Search in", selection: $scope) {
                        ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if scope == .online {
                        OnlineResultsView(model: online, text: query, unit: environment.energyUnit) { openOnline($0) }
                    } else {
                        if results.isEmpty, !searchFailed {
                            EmptyStateView(
                                "No matches",
                                systemImage: "magnifyingglass",
                                message: "Create the food to log it now, or search online.",
                            )
                            .listRowBackground(Color.clear)
                        }
                        ForEach(results) { result in
                            Button { open(result) } label: {
                                FoodRow(
                                    name: result.name, brand: result.brand, per100: result.per100, source: result.source,
                                    unit: environment.energyUnit, isLiquid: result.isLiquid,
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle(slotName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Scan barcode", systemImage: "barcode.viewfinder") { showScanner = true }
                    Button("Quick add", systemImage: "bolt") { showQuickAdd = true }
                    Button("Create food", systemImage: "plus") { showCreate = true }
                }
            }
            .navigationDestination(for: FoodDetail.self) { detail in
                QuantitySheet(detail: detail, mode: .log(slotID: target.slotID, day: target.day)) { dismiss() }
            }
            .task { reloadLists() }
            .task(id: query) { await runSearch() }
            .task(id: OnlineSearchKey(query: query.trimmingCharacters(in: .whitespacesAndNewlines), isOnline: scope == .online)) {
                guard scope == .online else { return }
                await online.search(query, offSearch: environment.offSearch, usda: environment.usda)
            }
            .sheet(item: $servingPrompt) { pending in
                ServingWeightPrompt(detail: pending.detail) { detail in
                    servingPrompt = nil
                    path.append(detail)
                }
            }
            .sheet(item: $loggingMeal, onDismiss: reloadLists) { meal in
                MealLogSheet(meal: meal, target: target) { dismiss() }
            }
            .sheet(item: $editingMeal, onDismiss: reloadLists) { selection in
                MealEditorView(mealID: selection.id)
            }
            .alert("Rename meal", isPresented: Binding(get: { renamingMeal != nil }, set: {
                if !$0 {
                    renamingMeal = nil
                }
            })) {
                TextField("Name", text: $mealName)
                Button("Save") { renameMeal() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showCreate) {
                FoodEditorView(initialName: query) { saved in
                    reloadLists()
                    path.append(saved)
                }
            }
            .fullScreenCover(isPresented: $showScanner, onDismiss: reloadLists) {
                ScanView(target: target) { dismiss() }
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
        case .meals: []
        }
    }

    private var emptyTitle: String {
        switch tab {
        case .recents: "Nothing logged yet"
        case .favorites: "No favorites"
        case .mine: "No custom foods"
        case .meals: "No saved meals"
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .recents: "Search above or create a food — it shows up here after you log it."
        case .favorites: "Tap the star on a food to keep it here."
        case .mine: "Foods you create appear here."
        case .meals: "Create a meal from foods in the Foods tab, or open a meal's menu in the diary and choose “Save as meal”."
        }
    }

    private func deleteMeal(_ meal: MealTemplateDetail) {
        do {
            try environment.meals?.softDelete(id: meal.id)
            reloadLists()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameMeal() {
        guard let meal = renamingMeal else { return }
        do {
            try environment.meals?.rename(id: meal.id, to: mealName)
            reloadLists()
        } catch let PersistenceError.validation(message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
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
            meals = try environment.meals?.templates() ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runSearch() async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let search = environment.search else {
            results = []
            searchFailed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(150)) // debounce typing
        guard !Task.isCancelled else { return }
        do {
            results = try search.search(text)
            searchFailed = false
        } catch {
            results = []
            searchFailed = true // don't claim "No matches" when the search didn't run
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func open(_ food: Food) {
        do {
            guard let detail = try environment.foods?.detail(id: food.id) else {
                errorMessage = "\(food.name) is no longer available."
                return
            }
            path.append(detail)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stores a local copy of the online food, then opens it (asking for the serving weight first when needed).
    private func openOnline(_ result: OnlineFoodResult) {
        guard let foods = environment.foods else { return }
        do {
            switch try online.select(result, in: foods) {
            case let .open(detail): path.append(detail)
            case let .askServingWeight(pending): servingPrompt = pending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

extension FoodSearchResult {
    /// Whether the row's "per 100" is ml. Bundled index values are per 100 g (their local copies are solids too).
    var isLiquid: Bool {
        if case let .food(food) = self {
            return food.isLiquid
        }
        return false
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
