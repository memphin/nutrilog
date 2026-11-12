import Core
import DesignSystem
import SwiftUI

/// Trends → Correlations → "Compare any two": any two measures, same day or next day, by day or by week. The same
/// spec → pairs → result path as the cards (`CorrelationAnalysis`).
struct CorrelationExplorerView: View {
    @Binding var period: CorrelationPeriod
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.correlationSource) private var source
    @State private var x: CorrelationMetric
    @State private var y: CorrelationMetric
    @State private var lag: CorrelationLag = .sameDay
    @State private var granularity: CorrelationGranularity = .daily
    @State private var stats: [DayStats]?

    /// Starts with sleep against the intake of the day after the night (the original FR-53 question).
    init(period: Binding<CorrelationPeriod>, x: CorrelationMetric = .sleep, y: CorrelationMetric = .calories) {
        _period = period
        _x = State(initialValue: x)
        _y = State(initialValue: y)
    }

    private var spec: CorrelationSpec {
        CorrelationSpec(x: x, y: y, lag: lag, granularity: granularity).normalized
    }

    var body: some View {
        Form {
            Section {
                CorrelationPeriodPicker(period: $period)
                Picker("X axis", selection: $x) {
                    ForEach(CorrelationMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Y axis", selection: $y) {
                    ForEach(CorrelationMetric.allCases) { Text($0.title).tag($0) }
                }
                // Weeks compare the same week; weight-trend change only exists per week. The pickers then show what
                // is used rather than what was last chosen.
                Picker("Pairing", selection: Binding(get: { spec.lag }, set: { lag = $0 })) {
                    ForEach(CorrelationLag.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(spec.granularity == .weekly)
                Picker("Grouping", selection: Binding(get: { spec.granularity }, set: { granularity = $0 })) {
                    ForEach(CorrelationGranularity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(spec.requiresWeekly)
            } footer: {
                Text(explanation)
            }
            Section {
                if let stats {
                    CorrelationResultView(analysis: CorrelationAnalysis.make(
                        spec, period: period, stats: stats, today: environment.today, unit: environment.energyUnit,
                        firstWeekday: Calendar.current.firstWeekday,
                    ))
                    .padding(.vertical, NL.Spacing.xs)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
        .navigationTitle("Compare any two")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: CorrelationExplorerKey(
            period: period, today: environment.today, generation: environment.dataGeneration,
            synced: environment.healthSync?.lastSyncedAt,
        )) {
            stats = source.load(CorrelationAnalysis.loadRange(period, today: environment.today), environment)
        }
    }

    /// How the two are paired, in one sentence.
    private var explanation: String {
        if spec.requiresWeekly {
            return String(localized: """
            Weight-trend change is measured over a week, so this compares weeks: each week's average with its \
            weight-trend change.
            """)
        }
        switch (spec.granularity, spec.lag) {
        case (.weekly, _):
            return String(localized: "Each week's average of one against the same week's average of the other.")
        case (.daily, .sameDay):
            return String(localized: "Each day's x value against the same day's y value. Sleep belongs to the morning it ends.")
        case (.daily, .nextDay):
            return String(localized: "Each day's x value against the next day's y value. Sleep belongs to the morning it ends.")
        }
    }
}

private struct CorrelationExplorerKey: Hashable {
    var period: CorrelationPeriod
    var today: LocalDay
    var generation: Int
    var synced: Date?
}
