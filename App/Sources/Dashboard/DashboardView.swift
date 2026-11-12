import Core
import DesignSystem
import Persistence
import SwiftUI

/// Today: intake, weight, steps, sleep and the other Health tiles (backlog #28, FR-41). Long-press a tile to edit the
/// layout right here (drag to reorder, hide, show); Settings → Dashboard edits the same layout. Pull to refresh
/// re-reads Health.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Opens in edit mode (debug screens).
    var startsEditing = false
    @State private var model: DashboardModel?

    var body: some View {
        Group {
            if let model {
                DashboardContent(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil {
                let model = DashboardModel(environment: environment)
                model.isEditing = startsEditing
                self.model = model
            }
        }
    }
}

private struct DashboardContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: DashboardModel
    @State private var path: [DashboardTile] = []
    /// The tile being dragged while editing the layout.
    @State private var dragging: DashboardTile?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: NL.Spacing.m) {
                    if let boost = model.trainingBoost {
                        TrainingDayPill(boostPercent: boost)
                    }
                    ForEach(model.layout.rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: NL.Spacing.m) {
                            ForEach(row) { tile in
                                DashboardTileView(tile: tile, model: model) { path.append(tile) }
                                    .modifier(EditableTile(tile: tile, model: model, dragging: $dragging))
                            }
                        }
                    }
                    if model.layout.visible.isEmpty {
                        EmptyStateView(
                            String(localized: "All tiles are hidden"),
                            systemImage: "square.grid.2x2",
                            message: model.isEditing
                                ? String(localized: "Tap + on a hidden tile below to show it again.")
                                : String(localized: "Edit Today to show them again, or use Settings → Dashboard."),
                        )
                        if !model.isEditing {
                            Button("Edit Today") { model.isEditing = true }
                                .buttonStyle(.bordered)
                        }
                    }
                    if model.isEditing {
                        HiddenTilesSection(model: model)
                    }
                }
                .padding(.horizontal, NL.Spacing.l)
                .padding(.bottom, NL.Spacing.xxl)
                // A drop outside any tile ends the drag (the order was already updated while dragging).
                .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { model.reloadSettings() } // sizes may have changed in Settings
            .refreshable { await model.refresh() }
            .navigationTitle("Today")
            .toolbar {
                if model.isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { withAnimation(.snappy) { model.isEditing = false } }
                    }
                }
            }
            .sensoryFeedback(.impact, trigger: model.isEditing) { _, editing in editing }
            .onDisappear {
                model.isEditing = false // another tab, or a tile's detail
                dragging = nil
            }
            .navigationDestination(for: DashboardTile.self) { tile in
                TileDetailView(tile: tile, model: model)
            }
            .undoToast(model.undo)
            .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: {
                if !$0 {
                    model.errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
        }
        .task(id: environment.today) { await model.observe() }
        // A tap on the hydration reminder: show that tile's detail (also when Today opens because of it).
        .onChange(of: environment.dashboardTileRequest, initial: true) { _, tile in
            guard let tile else { return }
            environment.dashboardTileRequest = nil
            model.isEditing = false
            path = [tile]
        }
        .task(id: environment.dataGeneration) {
            model.reloadSettings()
            model.undo.dismiss()
        }
    }
}

/// New weigh-in, or the entry being edited.
enum WeightSheetTarget: Identifiable {
    case new
    case edit(WeightEntry)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(entry): entry.id
        }
    }

    var entry: WeightEntry? {
        if case let .edit(entry) = self {
            return entry
        }
        return nil
    }
}

// MARK: - Tile

struct DashboardTileView: View {
    let tile: DashboardTile
    let model: DashboardModel
    let open: () -> Void

    var body: some View {
        if tile == .caffeine || tile == .water {
            // The caffeine in the body and where the day's hydration stands change by the minute.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                card(now: model.now)
            }
        } else {
            card(now: model.now)
        }
    }

    /// Tiles with buttons inside (quick-add) keep them reachable for VoiceOver.
    private var hasInlineButtons: Bool {
        tile == .water || tile == .caffeine
    }

    private var detailHint: String {
        tile == .caffeine ? String(localized: "Shows the caffeine curve and today's drinks") : String(localized: "Shows the last 14 days")
    }

    @ViewBuilder private func card(now: Date) -> some View {
        let state = model.state(of: tile)
        let snapshot = model.snapshot
        // Only for a tile with a value: no chart when there is no data or no access.
        let sparkline = state == .ready ? snapshot.sparkline(for: tile) : nil
        let trend = snapshot.accessibilityTrend(of: tile, state: state)
        let card = VStack(alignment: .leading, spacing: NL.Spacing.s) {
            header(trend: trend, now: now)
            if state == .ready {
                TileContent(tile: tile, model: model, now: now)
                if let sparkline {
                    SparklineView(sparkline: sparkline, tint: tile == .totalEnergy ? .orange : NL.Palette.trend) {
                        snapshot.goalColor(of: tile, value: $0.upper, day: $0.day)
                    }
                }
            } else {
                TilePlaceholder(state: state, model: model)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(NL.Spacing.m)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: NL.Radius.m))
        .contentShape(RoundedRectangle(cornerRadius: NL.Radius.m))
        // A tap on the tile opens its detail; buttons inside (water quick-add, Connect) keep their own taps.
        .onTapGesture(perform: open)

        if hasInlineButtons, state == .ready {
            // Keeps its quick-add buttons reachable; the header is the focusable "open details" button.
            card.accessibilityElement(children: .contain)
        } else {
            // One element: "Weight, 81.4 kilograms". Activating opens the detail.
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.accessibilityLabel(of: tile, state: state, energyUnit: model.energyUnit, now: now))
                .accessibilityValue(trend ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(detailHint)
                .accessibilityAction(.default, open)
                .accessibilityActions {
                    if state == .needsAccess {
                        Button("Connect Apple Health") { Task { await model.connectHealth() } }
                    }
                }
        }
    }

    @ViewBuilder private func header(trend: String?, now: Date) -> some View {
        let label = Label(tile.title, systemImage: tile.systemImage)
            .font(NL.Typography.label)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        HStack(alignment: .firstTextBaseline) {
            if hasInlineButtons {
                Button(action: open) { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.snapshot.accessibilityLabel(of: tile, state: .ready, now: now))
                    .accessibilityValue(trend ?? "")
                    .accessibilityHint(detailHint)
            } else {
                label
            }
            if let streak = model.snapshot.streak(for: tile) {
                Spacer(minLength: NL.Spacing.xs)
                StreakBadge(streak: streak)
            }
        }
    }
}

private struct TilePlaceholder: View {
    let state: TileState
    let model: DashboardModel

    var body: some View {
        if state == .loading {
            HStack(spacing: NL.Spacing.s) {
                ProgressView()
                Text(state.message ?? "").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                Text("No data").font(NL.Typography.smallNumber).foregroundStyle(.tertiary)
                Text(state.message ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .needsAccess {
                    Button("Connect") { Task { await model.connectHealth() } }
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }
}

private struct TileContent: View {
    @Environment(AppEnvironment.self) private var environment
    let tile: DashboardTile
    let model: DashboardModel
    let now: Date

    var body: some View {
        let snapshot = model.snapshot
        switch tile {
        case .energy:
            EnergyTileContent(totals: snapshot.totals, target: snapshot.target, unit: model.energyUnit)
        case .steps:
            // The goal itself is not written on the tile; the colour says how the day compares with it.
            ValueText(
                snapshot.steps.map { $0.formatted() } ?? "—", unit: String(localized: "steps", comment: "Unit under the step count"),
                color: snapshot.steps.map { GoalColor.steps(Double($0), goal: snapshot.stepGoal) } ?? .primary,
            )
        case .sleep:
            SleepTileContent(sleep: snapshot.sleep, goalMin: snapshot.sleepGoalMin)
        case .weight:
            if let weight = snapshot.weight {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    ValueText(
                        weight.latestKg.formatted(.number.precision(.fractionLength(1))), unit: "kg",
                        color: snapshot.baselineColor(of: .weight) ?? .primary,
                    )
                    if weight.latest.day != snapshot.today {
                        Text(Format.day(weight.latest.day, today: snapshot.today)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        case .bodyFat:
            if let fat = snapshot.bodyFat {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    ValueText(
                        fat.pct.formatted(.number.precision(.fractionLength(1))), unit: "%",
                        color: snapshot.baselineColor(of: .bodyFat) ?? .primary,
                    )
                    if fat.day != snapshot.today {
                        Text(Format.day(fat.day, today: snapshot.today)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        case .totalEnergy:
            if let burned = snapshot.energyBurned {
                TotalEnergyContent(burned: burned, activeGoalKcal: snapshot.activeEnergyGoalKcal, unit: model.energyUnit)
            }
        case .restingHeartRate:
            BaselineContent(
                comparison: snapshot.restingHR, unit: "bpm", today: snapshot.today, color: snapshot.baselineColor(of: .restingHeartRate),
            )
        case .hrv:
            BaselineContent(
                comparison: snapshot.hrv, unit: "ms", today: snapshot.today, showsDeviation: true, color: snapshot.baselineColor(of: .hrv),
            )
        case .water:
            WaterTileContent(day: model.hydrationDay(at: now), sizes: model.waterSizes) { model.addWater(ml: $0) }
        case .caffeine:
            CaffeineTileContent(
                status: model.caffeineStatus(at: now), drinks: snapshot.caffeineSettings.quickAddDrinks,
            ) { model.addCaffeine(drink: $0) }
        }
    }
}

private struct ValueText: View {
    let value: String
    let unit: String
    /// The colour of the number (goal colours); the unit stays secondary.
    var color: Color = .primary

    init(_ value: String, unit: String, color: Color = .primary) {
        self.value = value
        self.unit = unit
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.xs) {
            Text(value).font(NL.Typography.number).monospacedDigit().contentTransition(.numericText())
                .foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Active + resting energy. With only one part known, that part is shown under its own name — never as the total.
/// The active part is coloured by the active energy goal; the total is not (the resting part isn't up to you).
private struct TotalEnergyContent: View {
    let burned: EnergyBurned
    let activeGoalKcal: Int
    let unit: EnergyUnit

    private func activeColor(_ kcal: Double) -> Color {
        GoalColor.activeEnergy(kcal: kcal, goal: activeGoalKcal)
    }

    private func number(_ kcal: Double) -> String {
        unit.display(kcal).formatted(.number.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
            if let total = burned.totalKcal {
                ValueText(number(total), unit: unit.symbol)
                // Only the active part; the resting part is in the detail (owner feedback).
                if let active = burned.activeKcal {
                    Text("Active \(unit.format(active))").font(.footnote.weight(.semibold)).foregroundStyle(activeColor(active))
                }
            } else {
                if let active = burned.activeKcal {
                    let caption = String(localized: "\(unit.symbol) active", comment: "Energy unit, e.g. “kcal active”")
                    ValueText(number(active), unit: caption, color: activeColor(active))
                } else if let resting = burned.restingKcal {
                    let caption = String(localized: "\(unit.symbol) resting", comment: "Energy unit, e.g. “kcal resting”")
                    ValueText(number(resting), unit: caption)
                }
                Text(burned.activeKcal == nil ? "No active energy yet — no total" : "No resting energy yet — no total")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EnergyTileContent: View {
    let totals: Nutrients
    let target: Target?
    let unit: EnergyUnit

    var body: some View {
        HStack(alignment: .center, spacing: NL.Spacing.l) {
            EnergyRing(consumed: unit.display(totals.kcal), target: target.map { unit.display($0.kcal) }, unit: unit.symbol, lineWidth: 9)
                .frame(width: 96, height: 96)
            VStack(spacing: NL.Spacing.s) {
                MacroBar(macro: .protein, value: totals.proteinG, target: target?.proteinG)
                MacroBar(macro: .carbs, value: totals.carbsG, target: target?.carbsG)
                MacroBar(macro: .fat, value: totals.fatG, target: target?.fatG)
            }
        }
    }
}

/// Last night's sleep: just the time asleep, coloured by the sleep goal (#72). Time in bed, said so, when that is
/// all Health has. Stages are in the detail (#62).
private struct SleepTileContent: View {
    let sleep: SleepValue?
    let goalMin: Int

    var body: some View {
        if let asleep = sleep?.asleepMin {
            ValueText(DashboardFormat.duration(asleep), unit: "", color: GoalColor.sleep(minutes: Double(asleep), goal: goalMin))
        } else if let inBed = sleep?.inBedMin {
            ValueText(
                DashboardFormat.duration(inBed), unit: String(localized: "in bed"),
                color: GoalColor.sleep(minutes: Double(inBed), goal: goalMin),
            )
        }
    }
}

private struct BaselineContent: View {
    let comparison: BaselineComparison?
    let unit: String
    let today: LocalDay
    var showsDeviation = false
    /// Green, orange or red against the 30-day average (#74); nil without one.
    var color: Color?

    var body: some View {
        if let comparison {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                ValueText(comparison.value.formatted(.number.precision(.fractionLength(0))), unit: unit, color: color ?? .primary)
                Text("7-day avg \(comparison.average7.formatted(.number.precision(.fractionLength(0)))) \(unit)")
                    .font(.footnote).foregroundStyle(.secondary)
                if showsDeviation {
                    Text(comparison.deviationText ?? String(localized: "30-day average after a week of data"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if comparison.day != today {
                    Text(Format.day(comparison.day, today: today)).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The Hydration tile (spec §3): every drink of the day against the goal, coloured by where the day stands; water
/// and other drinks; today's drinks on the strip; quick-add buttons for plain water.
struct WaterTileContent: View {
    let day: HydrationDay
    let sizes: [Int]
    let add: (Int) -> Void

    var body: some View {
        // Green at the goal, orange behind pace or during a long gap without a drink, plain on pace.
        let color = GoalColor.hydration(day.status)
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            // No goal checkmark: the green value says it, and the header carries the streak bolt.
            ValueText(HydrationTileText.amount(day), unit: HydrationTileText.goal(day), color: color)
            Text(HydrationTileText.breakdown(day)).font(.footnote).foregroundStyle(.secondary)
            HydrationStrip(day: day)
            HStack(spacing: NL.Spacing.s) {
                ForEach(sizes, id: \.self) { size in
                    Button {
                        add(size)
                    } label: {
                        Label("+\(size) ml", systemImage: "drop.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(NL.Palette.water)
                    .accessibilityLabel("Add \(size) millilitres of water")
                }
            }
        }
    }
}

#Preview {
    DashboardView().environment(AppEnvironment.preview(sampleData: true))
}
