import Charts
import Core
import DesignSystem
import SwiftUI

/// Where the correlation screens read their days: the database, or in debug builds fixed sample days
/// (`-uiScreen correlations`).
struct CorrelationSource: Sendable {
    var load: @MainActor @Sendable (ClosedRange<LocalDay>, AppEnvironment) -> [DayStats]

    static let live = CorrelationSource { range, environment in
        (try? StatsLoader.load(range, environment: environment)) ?? []
    }

    #if DEBUG
        /// `days` cut to the requested range.
        static func fixed(_ days: [DayStats]) -> CorrelationSource {
            CorrelationSource { range, _ in days.filter { range.contains($0.day) } }
        }
    #endif
}

extension EnvironmentValues {
    @Entry var correlationSource: CorrelationSource = .live
}

/// What reloads the correlations: the period, a new day, new data, the energy unit or a Health sync.
private struct CorrelationKey: Hashable {
    var period: CorrelationPeriod
    var today: LocalDay
    var generation: Int
    var unit: EnergyUnit
    var synced: Date?
}

/// Trends → Correlations (FR-53): a period picker, the four insight cards and "Compare any two".
struct CorrelationsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.correlationSource) private var source
    @State private var period: CorrelationPeriod = .threeMonths
    @State private var analyses: [CorrelationCard: CorrelationAnalysis] = [:]

    var body: some View {
        Section {
            CorrelationPeriodPicker(period: $period)
                .task(id: CorrelationKey(
                    period: period, today: environment.today, generation: environment.dataGeneration,
                    unit: environment.energyUnit, synced: environment.healthSync?.lastSyncedAt,
                )) { load() }
            ForEach(CorrelationCard.allCases) { card in
                if let analysis = analyses[card] {
                    NavigationLink {
                        CorrelationDetailView(title: card.title, analysis: analysis)
                    } label: {
                        CorrelationCardView(title: card.title, systemImage: card.systemImage, analysis: analysis)
                    }
                } else {
                    Label(card.title, systemImage: card.systemImage)
                }
            }
            NavigationLink {
                CorrelationExplorerView(period: $period)
            } label: {
                Label("Compare any two", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } header: {
            Text("Correlations")
        } footer: {
            Text("A link doesn't prove that one causes the other.")
        }
    }

    private func load() {
        let today = environment.today
        let stats = source.load(CorrelationAnalysis.loadRange(period, today: today), environment)
        var result: [CorrelationCard: CorrelationAnalysis] = [:]
        for card in CorrelationCard.allCases {
            result[card] = CorrelationAnalysis.make(
                card.spec, period: period, stats: stats, today: today, unit: environment.energyUnit,
                firstWeekday: Calendar.current.firstWeekday,
            )
        }
        analyses = result
    }
}

struct CorrelationPeriodPicker: View {
    @Binding var period: CorrelationPeriod

    var body: some View {
        Picker("Period", selection: $period) {
            ForEach(CorrelationPeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// A card: title, the sentence, the strength and how many days or weeks it rests on.
struct CorrelationCardView: View {
    let title: String
    let systemImage: String
    let analysis: CorrelationAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xs) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            Text(CorrelationText.sentence(analysis)).font(.subheadline)
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, NL.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the scatter plot")
    }

    /// "Moderate positive link · Based on 42 days"; just "Not enough data" below the minimum (the sentence has the count).
    private var footnote: String {
        let strength = CorrelationText.strength(analysis.result)
        guard analysis.result.hasEnoughData else { return strength }
        return "\(strength) · \(CorrelationText.basedOn(analysis))"
    }
}

/// The scatter plot, the sentence, the strength, the sample and the period: the body of a card's detail and of
/// "Compare any two".
struct CorrelationResultView: View {
    let analysis: CorrelationAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.m) {
            if analysis.pairs.isEmpty {
                EmptyStateView(
                    String(localized: "No data"), systemImage: "chart.dots.scatter",
                    message: analysis.isWeekly
                        ? String(localized: "No weeks with both values in the \(analysis.period.spokenTitle).")
                        : String(localized: "No days with both values in the \(analysis.period.spokenTitle)."),
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                CorrelationScatterChart(analysis: analysis)
                    .frame(height: 260)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Scatter plot")
                    .accessibilityValue(CorrelationText.chartSummary(analysis))
            }
            Text(CorrelationText.sentence(analysis)).font(.body)
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(CorrelationText.strength(analysis.result)).font(.headline)
                Text("\(CorrelationText.basedOn(analysis)) · \(analysis.period.spokenTitle)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text("A link doesn't prove that one causes the other.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// One point per day or week, and the least-squares line.
struct CorrelationScatterChart: View {
    let analysis: CorrelationAnalysis

    var body: some View {
        let unit = analysis.unit
        let xLabel = CorrelationText.axisLabel(analysis.spec.x, unit: unit)
        let yLabel = CorrelationText.axisLabel(analysis.spec.y, unit: unit)
        Chart {
            ForEach(analysis.pairs) { pair in
                PointMark(x: .value(xLabel, pair.x), y: .value(yLabel, pair.y))
                    .symbolSize(28)
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .accessibilityLabel(pointTitle(pair))
                    .accessibilityValue(pointValue(pair))
            }
            if let fit = analysis.result.fit, let low = analysis.pairs.map(\.x).min(), let high = analysis.pairs.map(\.x).max() {
                ForEach([low, high], id: \.self) { x in
                    LineMark(x: .value(xLabel, x), y: .value(yLabel, fit.y(at: x)), series: .value("Series", "Fit"))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel(xLabel, alignment: .center)
        .chartYAxisLabel(yLabel)
    }

    /// "Tue 4 Nov" or "Week of 3 Nov".
    private func pointTitle(_ pair: CorrelationPair) -> String {
        let date = pair.day.startDate()
        return analysis.isWeekly
            ? String(localized: "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))")
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func pointValue(_ pair: CorrelationPair) -> String {
        let spec = analysis.spec, unit = analysis.unit
        return "\(spec.x.title) \(CorrelationText.format(pair.x, spec.x, unit: unit)), "
            + "\(spec.y.title) \(CorrelationText.format(pair.y, spec.y, unit: unit))"
    }
}

/// A card's detail: the scatter plot with its line, the sentence, strength, sample, period and the footnote.
struct CorrelationDetailView: View {
    let title: String
    let analysis: CorrelationAnalysis

    var body: some View {
        ScrollView {
            CorrelationResultView(analysis: analysis)
                .padding(NL.Spacing.l)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
