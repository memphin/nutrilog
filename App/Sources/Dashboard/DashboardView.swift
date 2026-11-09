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
    @State private var showCustomize = false
    @State private var weightSheet: WeightSheetTarget?

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
                        EmptyStateView("All tiles are hidden", systemImage: "square.grid.2x2", message: "Tap Edit to show them again.")
                    }
                }
                .padding(.horizontal, NL.Spacing.l)
                .padding(.bottom, NL.Spacing.xxl)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { model.reloadSettings() } // sizes may have changed in Settings
            .refreshable { await model.refresh() }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") { showCustomize = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Weight", systemImage: "scalemass") { weightSheet = .new }
                        ForEach(model.waterSizes, id: \.self) { size in
                            Button("\(size) ml water", systemImage: "drop") { model.addWater(ml: size) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: DashboardTile.self) { tile in
                TileDetailView(tile: tile, model: model)
            }
            .sheet(isPresented: $showCustomize) {
                DashboardCustomizeView(model: model)
            }
            .sheet(item: $weightSheet) { target in
                WeightEntrySheet(model: model, editing: target.entry)
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
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            Label(tile.title, systemImage: tile.systemImage)
                .font(NL.Typography.label)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            if state == .ready {
                TileContent(tile: tile, model: model)
            } else {
                TilePlaceholder(state: state, model: model)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(NL.Spacing.m)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: NL.Radius.m))
        .contentShape(RoundedRectangle(cornerRadius: NL.Radius.m))
        // A tap on the tile opens its detail; buttons inside (water quick-add) keep their own taps.
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", open)
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
                Text("—").font(NL.Typography.number).foregroundStyle(.tertiary)
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
            ValueText(snapshot.steps.map { $0.formatted() } ?? "—", unit: "steps")
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
        case .activeEnergy:
            let unit = model.energyUnit
            ValueText(snapshot.activeKcal.map { unit.display($0).formatted(.number.precision(.fractionLength(0))) } ?? "—", unit: unit.symbol)
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

    init(_ value: String, unit: String) {
        self.value = value
        self.unit = unit
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.xs) {
            Text(value).font(NL.Typography.number).monospacedDigit().contentTransition(.numericText())
            Text(unit).font(.footnote).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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

private struct SleepTileContent: View {
    let sleep: SleepValue?

    var body: some View {
        if let sleep {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                if let asleep = sleep.asleepMin {
                    ValueText(DashboardFormat.duration(asleep), unit: "asleep")
                } else if let inBed = sleep.inBedMin {
                    ValueText(DashboardFormat.duration(inBed), unit: "in bed")
                }
                if let inBed = sleep.inBedMin, sleep.asleepMin != nil {
                    Text("In bed \(DashboardFormat.duration(inBed))").font(.footnote).foregroundStyle(.secondary)
                }
                if sleep.hasStages {
                    Text([
                        sleep.coreMin.map { "Core \(DashboardFormat.duration($0))" },
                        sleep.deepMin.map { "Deep \(DashboardFormat.duration($0))" },
                        sleep.remMin.map { "REM \(DashboardFormat.duration($0))" },
                        sleep.awakeMin.map { "Awake \(DashboardFormat.duration($0))" },
                    ].compactMap(\.self).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                ValueText(water.totalMl.formatted(.number.precision(.fractionLength(0))), unit: "of \(DashboardFormat.ml(water.goalMl))")
                Spacer()
                if water.isGoalReached {
                    Label("Goal reached", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(NL.Palette.water)
                }
            }
            ProgressView(value: water.fraction)
                .tint(NL.Palette.water)
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

// MARK: - Customize

struct DashboardCustomizeView: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.layout.order) { tile in
                        Toggle(isOn: Binding(get: { model.layout.isVisible(tile) }, set: { model.setVisible(tile, $0) })) {
                            Label(tile.title, systemImage: tile.systemImage)
                        }
                    }
                    .onMove { model.moveTiles(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to reorder. Hidden tiles keep their place.")
                }
                Section {
                    Button("Reset to default") { model.resetLayout() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    DashboardView().environment(AppEnvironment.preview(sampleData: true))
}
