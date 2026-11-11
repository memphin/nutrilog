import Core
import DesignSystem
import Persistence
import SwiftUI

/// A tile's detail: its chart (FR-51, backlog #38) and the last 14 days as a list. Weight lists the manual entries
/// (edit, delete with undo); water lists today's entries (delete with undo). Caffeine has its own detail
/// (`CaffeineDetailView`).
struct TileDetailView: View {
    let tile: DashboardTile
    @Bindable var model: DashboardModel

    var body: some View {
        if tile == .caffeine {
            CaffeineDetailView(model: model)
        } else {
            MetricDetailView(tile: tile, model: model)
        }
    }
}

private struct MetricDetailView: View {
    let tile: DashboardTile
    @Bindable var model: DashboardModel
    @State private var weightSheet: WeightSheetTarget?
    @State private var rows: [TileHistoryRow] = []

    var body: some View {
        List {
            Section {
                if let metric = ChartMetric(tile: tile) {
                    MetricChartView(metric: metric)
                        .listRowInsets(EdgeInsets(top: NL.Spacing.m, leading: NL.Spacing.l, bottom: NL.Spacing.m, trailing: NL.Spacing.l))
                }
                if tile == .energy {
                    NavigationLink("Macros chart") { MetricChartScreen(metric: .macros) }
                }
            }
            switch tile {
            case .weight:
                Section {
                    Button("Add weight", systemImage: "plus") { weightSheet = .new }
                }
                manualWeights
            case .water:
                Section {
                    WaterTileContent(water: model.snapshot.water, sizes: model.waterSizes) { model.addWater(ml: $0) }
                } footer: {
                    Text("Water you log here is also written to Apple Health. Water from other apps is included in the total.")
                }
                todayWater
            default:
                EmptyView()
            }
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                        LabeledContent(Format.day(row.day, today: model.data.today)) {
                            Text(row.value ?? "—").monospacedDigit()
                                .foregroundStyle(row.value == nil ? .tertiary : .primary)
                        }
                        if let detail = row.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Last \(TileHistory.days) days")
            } footer: {
                if let description = tile.detailDescription {
                    Text(description)
                }
            }
            if tile == .water {
                Section {
                    NavigationLink("Quick-add sizes") { WaterSettingsView() }
                }
            }
        }
        .navigationTitle(tile.title)
        .refreshable { await model.refresh() }
        .task(id: model.data) { rows = model.history(for: tile) }
        .sheet(item: $weightSheet) { target in
            WeightEntrySheet(model: model, editing: target.entry)
        }
        .undoToast(model.undo)
    }

    @ViewBuilder private var manualWeights: some View {
        let entries = model.data.manualWeights.reversed()
        if !entries.isEmpty {
            Section("Entered in Vitalion") {
                ForEach(Array(entries)) { entry in
                    Button {
                        weightSheet = .edit(entry)
                    } label: {
                        LabeledContent {
                            Text([DashboardFormat.kg(entry.kg), entry.bodyFatPct.map(DashboardFormat.percent)]
                                .compactMap(\.self).joined(separator: " · "))
                                .monospacedDigit()
                        } label: {
                            Text(entry.measuredAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.deleteWeight(entry) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var todayWater: some View {
        let entries = model.data.water.reversed()
        if !entries.isEmpty {
            Section("Logged today") {
                ForEach(Array(entries)) { entry in
                    LabeledContent(entry.loggedAt.formatted(date: .omitted, time: .shortened), value: DashboardFormat.ml(entry.ml))
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.deleteWater([entry]) }
                        }
                }
            }
        }
    }
}
