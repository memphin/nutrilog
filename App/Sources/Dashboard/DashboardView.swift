import Core
import DesignSystem
import Persistence
import SwiftUI

/// Today: intake, weight, steps, sleep and the other Health tiles (backlog #28, FR-41). Reorderable and hideable;
/// pull to refresh re-reads Health.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
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
                model = DashboardModel(environment: environment)
            }
        }
    }
}

private struct DashboardContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: DashboardModel
    @State private var path: [DashboardTile] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: NL.Spacing.m) {
                    ForEach(model.layout.rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: NL.Spacing.m) {
                            ForEach(row) { tile in
                                DashboardTileView(tile: tile, model: model) { path.append(tile) }
                            }
                        }
                    }
                    if model.layout.visible.isEmpty {
                        EmptyStateView(
                            "All tiles are hidden",
                            systemImage: "square.grid.2x2",
                            message: "Show them again in Settings → Dashboard.",
                        )
                    }
                }
                .padding(.horizontal, NL.Spacing.l)
                .padding(.bottom, NL.Spacing.xxl)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { model.reloadSettings() } // sizes may have changed in Settings
            .refreshable { await model.refresh() }
            .navigationTitle("Today")
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
        let state = model.state(of: tile)
        let snapshot = model.snapshot
        // Only for a tile with a value: no chart when there is no data or no access.
        let sparkline = state == .ready ? snapshot.sparkline(for: tile) : nil
        let trend = snapshot.accessibilityTrend(of: tile, state: state)
        let card = VStack(alignment: .leading, spacing: NL.Spacing.s) {
            header(trend: trend)
            if state == .ready {
                TileContent(tile: tile, model: model)
                if let sparkline {
                    SparklineView(sparkline: sparkline, tint: tile == .totalEnergy ? .orange : NL.Palette.trend) {
                        snapshot.goalColor(of: tile, value: $0.value)
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

        if tile == .water, state == .ready {
            // Keeps its quick-add buttons reachable; the header is the focusable "open details" button.
            card.accessibilityElement(children: .contain)
        } else {
            // One element: "Weight, 81.4 kilograms, trend 81.2, down 0.4 in 7 days". Activating opens the detail.
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.accessibilityLabel(of: tile, state: state, energyUnit: model.energyUnit))
                .accessibilityValue(trend ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the last 14 days")
                .accessibilityAction(.default, open)
                .accessibilityActions {
                    if state == .needsAccess {
                        Button("Connect Apple Health") { Task { await model.connectHealth() } }
                    }
                }
        }
    }

    @ViewBuilder private func header(trend: String?) -> some View {
        let label = Label(tile.title, systemImage: tile.systemImage)
            .font(NL.Typography.label)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        if tile == .water {
            Button(action: open) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(model.snapshot.accessibilityLabel(of: .water, state: .ready))
                .accessibilityValue(trend ?? "")
                .accessibilityHint("Shows the last 14 days")
        } else {
            label
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

    var body: some View {
        let snapshot = model.snapshot
        switch tile {
        case .energy:
            EnergyTileContent(totals: snapshot.totals, target: snapshot.target, unit: model.energyUnit)
        case .steps:
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                ValueText(
                    snapshot.steps.map { $0.formatted() } ?? "—", unit: "steps",
                    color: snapshot.steps.map { GoalColor.steps(Double($0), goal: snapshot.stepGoal) } ?? .primary,
                )
                Text("Goal \(snapshot.stepGoal.formatted())").font(.footnote).foregroundStyle(.secondary)
            }
        case .sleep:
            SleepTileContent(sleep: snapshot.sleep)
        case .weight:
            if let weight = snapshot.weight {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    ValueText(weight.latestKg.formatted(.number.precision(.fractionLength(1))), unit: "kg")
                    Text("Trend \(DashboardFormat.kg(weight.trendKg))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(weight.trendChange7d.map { "\(DashboardFormat.kgChange($0)) in 7 days" } ?? "7-day change soon")
                        .font(.footnote).foregroundStyle(.secondary)
                    if weight.latest.day != snapshot.today {
                        Text(Format.day(weight.latest.day, today: snapshot.today)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        case .bodyFat:
            if let fat = snapshot.bodyFat {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    ValueText(fat.pct.formatted(.number.precision(.fractionLength(1))), unit: "%")
                    if fat.day != snapshot.today {
                        Text(Format.day(fat.day, today: snapshot.today)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        case .totalEnergy:
            if let burned = snapshot.energyBurned {
                TotalEnergyContent(burned: burned, unit: model.energyUnit)
            }
        case .restingHeartRate:
            BaselineContent(comparison: snapshot.restingHR, unit: "bpm", today: snapshot.today)
        case .hrv:
            BaselineContent(comparison: snapshot.hrv, unit: "ms", today: snapshot.today, showsDeviation: true)
        case .water:
            WaterTileContent(water: snapshot.water, sizes: model.waterSizes) { model.addWater(ml: $0) }
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
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Active + resting energy. With only one part known, that part is shown under its own name — never as the total.
private struct TotalEnergyContent: View {
    let burned: EnergyBurned
    let unit: EnergyUnit

    private func number(_ kcal: Double) -> String {
        unit.display(kcal).formatted(.number.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
            if let total = burned.totalKcal {
                ValueText(number(total), unit: unit.symbol)
                Text(burned.breakdown(unit))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let active = burned.activeKcal {
                    ValueText(number(active), unit: "\(unit.symbol) active")
                } else if let resting = burned.restingKcal {
                    ValueText(number(resting), unit: "\(unit.symbol) resting")
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

/// Last night's sleep: the time asleep only (time in bed when that is all Health has). Stages are in the detail (#62).
private struct SleepTileContent: View {
    let sleep: SleepValue?

    var body: some View {
        if let asleep = sleep?.asleepMin {
            ValueText(DashboardFormat.duration(asleep), unit: "asleep")
        } else if let inBed = sleep?.inBedMin {
            ValueText(DashboardFormat.duration(inBed), unit: "in bed")
        }
    }
}

private struct BaselineContent: View {
    let comparison: BaselineComparison?
    let unit: String
    let today: LocalDay
    var showsDeviation = false

    var body: some View {
        if let comparison {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                ValueText(comparison.value.formatted(.number.precision(.fractionLength(0))), unit: unit)
                Text("7-day avg \(comparison.average7.formatted(.number.precision(.fractionLength(0)))) \(unit)")
                    .font(.footnote).foregroundStyle(.secondary)
                if showsDeviation {
                    Text(comparison.deviationText ?? "30-day average after a week of data")
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

struct WaterTileContent: View {
    let water: WaterProgress
    let sizes: [Int]
    let add: (Int) -> Void

    var body: some View {
        // Red below the goal, green once it is reached (#64).
        let goalColor = GoalColor.water(water.totalMl, goalMl: water.goalMl)
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                ValueText(
                    water.totalMl.formatted(.number.precision(.fractionLength(0))), unit: "of \(DashboardFormat.ml(water.goalMl))",
                    color: goalColor,
                )
                Spacer()
                if water.isGoalReached {
                    Label("Goal reached", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(goalColor)
                }
            }
            ProgressView(value: water.fraction)
                .tint(goalColor)
                .accessibilityLabel("Water")
                .accessibilityValue("\(Int(water.totalMl)) of \(Int(water.goalMl)) millilitres")
            if water.otherAppsMl > 0 {
                Text("Includes \(DashboardFormat.ml(water.otherAppsMl)) from other apps")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
