import Core
import DesignSystem
import Persistence
import SwiftUI

/// A tile's detail: its chart (FR-51, backlog #38). Weight adds a weigh-in and links to the manual entries (edit,
/// delete with undo). Hydration and caffeine have their own details (`HydrationDetailView`, `CaffeineDetailView`); last
/// week opens the weekly report.
struct TileDetailView: View {
    let tile: DashboardTile
    @Bindable var model: DashboardModel

    var body: some View {
        switch tile {
        case .caffeine:
            CaffeineDetailView(model: model)
        case .water:
            HydrationDetailView(model: model)
        case .weeklyReport:
            WeeklyReportView(weekStart: model.thisWeekStart)
        default:
            MetricDetailView(tile: tile, model: model)
        }
    }
}

private struct MetricDetailView: View {
    let tile: DashboardTile
    @Bindable var model: DashboardModel
    @State private var weightSheet: WeightSheetTarget?

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
            } footer: {
                if let description = tile.detailDescription {
                    Text(description)
                }
            }
            switch tile {
            case .weight:
                Section {
                    Button("Add weight", systemImage: "plus") { weightSheet = .new }
                }
                Section {
                    // Loaded on demand: the dashboard only reads its history window.
                    NavigationLink("All weigh-ins") { AllWeighInsView(model: model) }
                } footer: {
                    Text("Every weight entered in Vitalion, however old.")
                }
            default:
                EmptyView()
            }
        }
        .navigationTitle(tile.title)
        .refreshable { await model.refresh() }
        .sheet(item: $weightSheet) { target in
            WeightEntrySheet(model: model, editing: target.entry)
        }
        .undoToast(model.undo)
    }
}

/// A weigh-in entered in Vitalion: tap to edit, swipe to delete (with undo).
private struct ManualWeightRow: View {
    let entry: WeightEntry
    let model: DashboardModel
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            LabeledContent {
                Text([Format.kg(entry.kg), entry.bodyFatPct.map(Format.percent)]
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

/// Every manual weigh-in, newest first, also those older than the dashboard's history window. Observed only while
/// this screen is open.
private struct AllWeighInsView: View {
    @Bindable var model: DashboardModel
    @State private var weightSheet: WeightSheetTarget?

    var body: some View {
        List {
            if let entries = model.allManualWeights {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No weigh-ins", systemImage: "scalemass", description: Text("Weights you enter in Vitalion appear here."),
                    )
                } else {
                    ForEach(entries) { entry in
                        ManualWeightRow(entry: entry, model: model) { weightSheet = .edit(entry) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("All weigh-ins")
        .task { await model.observeAllWeights() }
        .sheet(item: $weightSheet) { target in
            WeightEntrySheet(model: model, editing: target.entry)
        }
        .undoToast(model.undo)
    }
}
