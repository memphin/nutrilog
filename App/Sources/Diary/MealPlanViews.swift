import Core
import DesignSystem
import Persistence
import SwiftUI

// MARK: - Diary rows

/// A planned food in a diary meal: not counted until it is confirmed as eaten.
struct PlannedRow: View {
    let entry: PlannedEntry
    let unit: EnergyUnit
    var isLiquid = false
    /// Today or earlier: the check mark logs it. A future plan only shows a calendar mark.
    let canConfirm: Bool
    let onConfirm: () -> Void

    private var caption: String {
        guard !entry.isQuickAdd else { return "Planned" }
        return "Planned · " + Format.amount(grams: entry.grams, unit: BaseUnit(isLiquid: isLiquid), servingLabel: entry.servingLabel)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.m) {
            if canConfirm {
                Button(action: onConfirm) {
                    Image(systemName: "circle")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Mark \(entry.displayName) as eaten")
            } else {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(entry.displayName)
                    .lineLimit(2)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            Spacer()
            Text(unit.format(entry.kcal))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Planned 1 850 kcal · with eaten ≈ 2 300 of 2 200", with a button to confirm the whole plan.
struct PlannedSummaryRow: View {
    let planned: Nutrients
    let eaten: Nutrients
    let target: Target?
    let unit: EnergyUnit
    let canConfirm: Bool
    let onConfirmAll: () -> Void

    var body: some View {
        HStack(spacing: NL.Spacing.m) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text("Planned \(unit.format(planned.kcal))")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canConfirm {
                Button("All eaten", action: onConfirmAll)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Logs every planned food of this day")
            }
        }
    }

    private var detail: String {
        let total = planned.kcal + eaten.kcal
        var text = eaten.kcal > 0 ? "With eaten ≈ \(unit.format(total))" : "≈ \(unit.format(total))"
        if let target {
            text += " of \(unit.format(target.kcal))"
        }
        let macros = [("P", planned.proteinG), ("C", planned.carbsG), ("F", planned.fatG)]
            .map { "\($0.0) \(DisplayRounding.whole($0.1)) g" }
        return ([text] + macros).joined(separator: " · ")
    }
}

// MARK: - Sheets

/// Changes the amount of a planned food.
struct EditPlannedView: View {
    let entry: PlannedEntry
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuantitySheet(detail: detail, mode: .editPlanned(entry)) { dismiss() }
        }
    }

    /// The food if it still exists; otherwise a stand-in from the plan's estimate.
    private var detail: FoodDetail {
        if let id = entry.foodID, let detail = try? environment.foods?.detail(id: id) {
            return detail
        }
        let per100 = entry.grams > 0 ? entry.nutrients.scaled(by: 100 / entry.grams) : entry.nutrients
        return FoodDetail(food: Food(id: entry.foodID ?? entry.id, name: entry.displayName, per100: per100))
    }
}

/// "Plan for the next days…": how many following days get the same meal (or day), e.g. a prepped lunch for the week.
struct RepeatPlanSheet: View {
    let title: String
    let from: LocalDay
    let onPlan: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var days = 4

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Next \(days) \(days == 1 ? "day" : "days")", value: $days, in: 1 ... 13)
                } footer: {
                    Text("Adds it to the plan from \(Self.label(from.next)) to \(Self.label(from.adding(days: days))). "
                        + "Nothing is logged until you mark it as eaten on the day.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Plan") {
                        onPlan(days)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func label(_ day: LocalDay) -> String {
        day.startDate().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Week plan and prep list

/// The next 7 days at a glance, and a prep list that sums up what to cook or buy for them.
struct MealPlanView: View {
    /// Shows a day in the diary.
    let onOpenDay: (LocalDay) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.week
    @State private var planned: [PlannedEntry] = []
    @State private var eaten: [LocalDay: Double] = [:]
    @State private var targets: [LocalDay: Double] = [:]
    @State private var slots: [String: String] = [:]
    @State private var liquidFoodIDs: Set<String> = []
    @State private var prepDays = 7
    @State private var prepFromTomorrow = false
    /// Ticked off while cooking or shopping; kept only while the sheet is open.
    @State private var prepped: Set<String> = []
    @State private var errorMessage: String?

    enum Tab: Hashable { case week, prep }

    static let horizon = 7

    private var today: LocalDay {
        environment.today
    }

    private var unit: EnergyUnit {
        environment.energyUnit
    }

    private var days: [LocalDay] {
        (0 ..< Self.horizon).map { today.adding(days: $0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("View", selection: $tab) {
                        Text("Week").tag(Tab.week)
                        Text("Prep list").tag(Tab.prep)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch tab {
                case .week: week
                case .prep: prep
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Meal plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if tab == .prep, !prepItems.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: prepText) { Label("Share list", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .task(id: today) { await observePlan() }
            .task(id: today) { await observeEaten() }
            .task(id: today) { loadTargetsAndSlots() }
            .alert("Meal plan", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Week

    @ViewBuilder
    private var week: some View {
        ForEach(days, id: \.self) { day in
            let entries = planned.filter { $0.day == day }
            Section {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                            Text(entry.displayName).lineLimit(2)
                            Text([slots[entry.mealSlotID], amount(entry)].compactMap(\.self).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(unit.format(entry.kcal))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    open(day)
                } label: {
                    Label(entries.isEmpty ? "Plan this day" : "Open in diary", systemImage: entries.isEmpty ? "plus" : "arrow.right")
                }
            } header: {
                dayHeader(day, entries: entries)
            }
        }
        Section {} footer: {
            Text("Plan a day by opening it in the diary and adding food. To prep the same meal for several days, "
                + "use “Plan for the next days…” in a meal's menu. Planned food counts only once you mark it as eaten.")
        }
    }

    private func dayHeader(_ day: LocalDay, entries: [PlannedEntry]) -> some View {
        HStack {
            Text(Format.day(day, today: today))
            Spacer()
            let total = entries.reduce(0) { $0 + $1.kcal } + (eaten[day] ?? 0)
            if total > 0 {
                Text(targets[day].map { "\(DisplayRounding.whole(unit.display(total))) / \(unit.format($0))" } ?? unit.format(total))
                    .monospacedDigit()
            }
        }
    }

    private func open(_ day: LocalDay) {
        onOpenDay(day)
        dismiss()
    }

    // MARK: Prep list

    private var prepRange: ClosedRange<LocalDay> {
        Self.prepRange(today: today, fromTomorrow: prepFromTomorrow, days: prepDays)
    }

    /// The days the prep list sums up: `days` days from today, or from tomorrow (then up to `today + horizon`).
    static func prepRange(today: LocalDay, fromTomorrow: Bool, days: Int) -> ClosedRange<LocalDay> {
        let start = fromTomorrow ? today.next : today
        return start ... start.adding(days: max(days, 1) - 1)
    }

    /// The plan loaded for the sheet: the week (`today` to `today + horizon - 1`) plus the day after it, which the prep
    /// list reaches when it starts tomorrow. The week view shows only its own days.
    static func planWindow(today: LocalDay) -> ClosedRange<LocalDay> {
        today ... today.adding(days: horizon)
    }

    private var prepItems: [PrepItem] {
        MealPlanRepository.prepList(planned.filter { prepRange.contains($0.day) })
    }

    @ViewBuilder
    private var prep: some View {
        Section {
            Stepper("\(prepDays) \(prepDays == 1 ? "day" : "days")", value: $prepDays, in: 1 ... Self.horizon)
            Toggle("Start tomorrow", isOn: $prepFromTomorrow)
        } footer: {
            Text("\(RepeatPlanSheet.label(prepRange.lowerBound)) – \(RepeatPlanSheet.label(prepRange.upperBound)). "
                + "Sums up planned food that isn't eaten yet.")
        }
        let items = prepItems
        if items.isEmpty {
            Section {
                Text("Nothing planned for these days.").foregroundStyle(.secondary)
            }
        } else {
            Section("To prep") {
                ForEach(items) { item in
                    Button {
                        if prepped.contains(item.id) {
                            prepped.remove(item.id)
                        } else {
                            prepped.insert(item.id)
                        }
                    } label: {
                        prepRow(item, done: prepped.contains(item.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(prepped.contains(item.id) ? .isSelected : [])
                }
            }
            Section {
                LabeledContent("Planned energy", value: unit.format(items.reduce(0) { $0 + $1.nutrients.kcal }))
                    .monospacedDigit()
            }
        }
    }

    private func prepRow(_ item: PrepItem, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(item.name)
                    .strikethrough(done)
                Text("\(item.portions) \(item.portions == 1 ? "portion" : "portions") · \(dayList(item.days))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(totalAmount(item))
                .monospacedDigit()
                .foregroundStyle(done ? .secondary : .primary)
        }
        .contentShape(Rectangle())
    }

    private func totalAmount(_ item: PrepItem) -> String {
        if item.isQuickAdd || item.totalGrams <= 0 {
            return unit.format(item.nutrients.kcal)
        }
        let base = BaseUnit(isLiquid: item.foodID.map(liquidFoodIDs.contains) ?? false)
        return "\(NutrientRow.format(item.totalGrams, unit: base.symbol)) \(base.symbol)"
    }

    private func dayList(_ days: [LocalDay]) -> String {
        days.map { $0.startDate().formatted(.dateTime.weekday(.abbreviated)) }.joined(separator: ", ")
    }

    /// Plain text for the share sheet (notes, reminders, a shopping list).
    private var prepText: String {
        let header = "Meal prep \(RepeatPlanSheet.label(prepRange.lowerBound)) – \(RepeatPlanSheet.label(prepRange.upperBound))"
        let lines = prepItems.map { "• \($0.name): \(totalAmount($0)) (\($0.portions)×)" }
        return ([header] + lines).joined(separator: "\n")
    }

    private func amount(_ entry: PlannedEntry) -> String? {
        guard !entry.isQuickAdd else { return nil }
        let isLiquid = entry.foodID.map(liquidFoodIDs.contains) ?? false
        return Format.amount(grams: entry.grams, unit: BaseUnit(isLiquid: isLiquid), servingLabel: entry.servingLabel)
    }

    // MARK: Loading

    private func observePlan() async {
        guard let repo = environment.mealPlan else { return }
        let range = Self.planWindow(today: today)
        await DiaryModel.resubscribing {
            repo.observePending(in: range)
        } onValue: { value in
            planned = value
            let ids = Set(value.compactMap(\.foodID))
            liquidFoodIDs = Set(ids.filter { (try? environment.foods?.food(id: $0))??.isLiquid == true })
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    private func observeEaten() async {
        guard let repo = environment.diary else { return }
        let range = today ... today.adding(days: Self.horizon - 1)
        await DiaryModel.resubscribing {
            repo.observeDaySummaries(in: range)
        } onValue: { value in
            eaten = Dictionary(value.map { ($0.day, $0.totals.kcal) }, uniquingKeysWith: { $1 })
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    private func loadTargetsAndSlots() {
        var result: [LocalDay: Double] = [:]
        for day in days {
            if let target = try? environment.profiles?.target(on: day) {
                result[day] = target.kcal
            }
        }
        targets = result
        let all = (try? environment.diary?.mealSlots(includeInactive: true)) ?? []
        slots = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
    }
}
