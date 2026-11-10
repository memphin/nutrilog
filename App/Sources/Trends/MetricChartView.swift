import Charts
import Core
import DesignSystem
import SwiftUI

/// A chart of one metric with 1W / 1M / 3M / 1Y ranges, scrubbing and an average line (FR-51, backlog #38).
/// Used on its own screen (Trends → Charts) and at the top of each dashboard tile's detail.
struct MetricChartView: View {
    let metric: ChartMetric
    @Environment(AppEnvironment.self) private var environment
    @State private var range: ChartRange = .month
    @State private var series: ChartSeries?
    @State private var selectedDate: Date?
    /// The daily goal the bars are coloured by: steps (#63), ml of water (#64) or hours of sleep (#72); nil for the other metrics.
    @State private var goal: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.m) {
            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if let series {
                header(series)
                if series.isEmpty {
                    EmptyStateView("No data", systemImage: metric.systemImage, message: "Nothing recorded in the \(range.spokenTitle).")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    chart(series)
                        .frame(height: 220)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(metric.title) chart")
                        .accessibilityValue(ChartBuilder.summary(series, unit: environment.energyUnit))
                }
                Text(ChartBuilder.summary(series, unit: environment.energyUnit))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .task(id: Key(
            range: range, today: environment.today, generation: environment.dataGeneration, unit: environment.energyUnit,
            synced: environment.healthSync?.lastSyncedAt,
        )) {
            load()
        }
    }

    private struct Key: Hashable {
        var range: ChartRange
        var today: LocalDay
        var generation: Int
        var unit: EnergyUnit
        var synced: Date?
    }

    private func load() {
        selectedDate = nil
        goal = switch metric {
        case .steps: environment.profiles.map { Double(StepGoal.load(from: $0)) }
        // The sleep chart is in hours.
        case .sleep: environment.profiles.map { Double(SleepGoal.load(from: $0)) / 60 }
        case .water: try? environment.profiles?.profile().waterGoalMl
        default: nil
        }
        let stats = (try? StatsLoader.load(range.days(endingOn: environment.today), environment: environment)) ?? []
        series = ChartBuilder.series(
            metric, range: range, stats: stats, unit: environment.energyUnit, firstWeekday: Calendar.current.firstWeekday,
            today: environment.today,
        )
    }

    // MARK: Header (selection or average)

    private func selectedPoint(_ series: ChartSeries) -> ChartPoint? {
        guard let selectedDate else { return nil }
        let day = LocalDay(selectedDate)
        return series.points.last { $0.day <= day && day < $0.day.adding(days: $0.spanDays) }
    }

    @ViewBuilder
    private func header(_ series: ChartSeries) -> some View {
        let unit = environment.energyUnit
        if let point = selectedPoint(series) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(pointTitle(point)).font(.caption).foregroundStyle(.secondary)
                Text(pointValue(point)).font(NL.Typography.number).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(metric.isBar ? "Daily average" : "Average").font(.caption).foregroundStyle(.secondary)
                Text(series.average.map { ChartBuilder.format($0, metric, unit: unit) } ?? "—")
                    .font(NL.Typography.number).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func pointTitle(_ point: ChartPoint) -> String {
        guard point.spanDays > 1 else {
            return point.day.startDate().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return "Week of \(point.day.startDate().formatted(.dateTime.day().month(.abbreviated))) · daily average"
    }

    private func pointValue(_ point: ChartPoint) -> String {
        let unit = environment.energyUnit
        var parts: [String] = []
        if metric == .macros {
            if let protein = point.proteinG, let carbs = point.carbsG, let fat = point.fatG {
                parts.append("P \(Int(protein.rounded())) g · C \(Int(carbs.rounded())) g · F \(Int(fat.rounded())) g")
            } else {
                parts.append("Not logged")
            }
        } else {
            parts.append(point.value.map { ChartBuilder.format($0, metric, unit: unit) } ?? "No value")
        }
        if let resting = point.resting, let active = point.active {
            func number(_ value: Double) -> String {
                value.formatted(.number.precision(.fractionLength(0)))
            }
            parts.append("resting \(number(resting)) + active \(number(active))")
        }
        if let reference = point.reference {
            parts.append(metric == .weight
                ? "trend \(reference.formatted(.number.precision(.fractionLength(1)))) kg"
                : "target \(ChartBuilder.format(reference, metric, unit: unit))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Chart

    private func date(_ point: ChartPoint) -> Date {
        point.day.startDate()
    }

    private func chart(_ series: ChartSeries) -> some View {
        let component: Calendar.Component = series.bucketDays == 7 ? .weekOfYear : .day
        return Chart {
            ForEach(series.points) { point in
                marks(point, series: series, component: component)
            }
            if let average = series.average, metric != .macros {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("avg").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Average")
                    .accessibilityValue(ChartBuilder.format(average, metric, unit: environment.energyUnit))
            }
            if let goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("goal").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Goal")
                    .accessibilityValue(ChartBuilder.format(goal, metric, unit: environment.energyUnit))
            }
            if let point = selectedPoint(series) {
                RuleMark(x: .value("Selected", date(point).addingTimeInterval(Double(point.spanDays) * 43200)))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(
            domain: metric == .totalEnergy ? ["Resting", "Active"] : ["Protein", "Carbs", "Fat"],
            range: metric == .totalEnergy
                ? [Color.orange.opacity(0.45), Color.orange]
                : [NL.Palette.protein, NL.Palette.carbs, NL.Palette.fat],
        )
        .chartLegend(metric == .macros || metric == .totalEnergy ? .visible : .hidden)
        .chartYScale(domain: .automatic(includesZero: metric.isBar))
        .chartXSelection(value: $selectedDate)
    }

    @ChartContentBuilder
    private func marks(_ point: ChartPoint, series: ChartSeries, component: Calendar.Component) -> some ChartContent {
        switch metric {
        case .macros:
            if let protein = point.proteinG, let carbs = point.carbsG, let fat = point.fatG {
                BarMark(x: .value("Day", date(point), unit: component), y: .value("Grams", protein))
                    .foregroundStyle(by: .value("Macro", "Protein"))
                BarMark(x: .value("Day", date(point), unit: component), y: .value("Grams", carbs))
                    .foregroundStyle(by: .value("Macro", "Carbs"))
                BarMark(x: .value("Day", date(point), unit: component), y: .value("Grams", fat))
                    .foregroundStyle(by: .value("Macro", "Fat"))
            }
        case .energy:
            if let value = point.value {
                BarMark(x: .value("Day", date(point), unit: component), y: .value(series.unitLabel, value))
                    .foregroundStyle(Adherence.band(kcal: value, targetKcal: point.reference).color.opacity(0.8))
            }
            if let target = point.reference {
                LineMark(
                    x: .value("Day", date(point), unit: component),
                    y: .value(series.unitLabel, target),
                    series: .value("Series", "Target"),
                )
                .interpolationMethod(.stepCenter)
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        case .totalEnergy:
            // One bar per day (or week): resting below, active on top.
            if let resting = point.resting, let active = point.active {
                BarMark(x: .value("Day", date(point), unit: component), y: .value(series.unitLabel, resting))
                    .foregroundStyle(by: .value("Part", "Resting"))
                BarMark(x: .value("Day", date(point), unit: component), y: .value(series.unitLabel, active))
                    .foregroundStyle(by: .value("Part", "Active"))
            }
        case .steps, .water, .sleep:
            if let value = point.value {
                BarMark(x: .value("Day", date(point), unit: component), y: .value(series.unitLabel, value))
                    .foregroundStyle(goalColor(value).opacity(0.85))
            }
        case .weight:
            if let value = point.value {
                PointMark(x: .value("Day", date(point), unit: .day), y: .value("kg", value))
                    .symbolSize(18)
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            if let trend = point.reference {
                LineMark(x: .value("Day", date(point), unit: .day), y: .value("kg", trend), series: .value("Series", "Trend"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        default:
            if let value = point.value {
                if metric.isBar {
                    BarMark(x: .value("Day", date(point), unit: component), y: .value(series.unitLabel, value))
                        .foregroundStyle(tint)
                } else {
                    LineMark(x: .value("Day", date(point), unit: .day), y: .value(series.unitLabel, value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                    PointMark(x: .value("Day", date(point), unit: .day), y: .value(series.unitLabel, value))
                        .symbolSize(14)
                        .foregroundStyle(tint)
                }
            }
        }
    }

    /// Steps: green at the goal, orange close below, red further away. Water: red below the goal, green at it.
    private func goalColor(_ value: Double) -> Color {
        guard let goal else { return tint }
        switch metric {
        case .water: return GoalColor.water(value, goalMl: goal)
        case .sleep: return GoalColor.sleep(minutes: value * 60, goal: Int((goal * 60).rounded()))
        default: return GoalColor.steps(value, goal: Int(goal))
        }
    }

    private var tint: Color {
        switch metric {
        case .water: NL.Palette.water
        case .sleep: .indigo
        case .steps, .totalEnergy: .orange
        case .restingHeartRate: .red
        case .hrv: .purple
        default: .accentColor
        }
    }
}

/// Trends → Charts → one metric.
struct MetricChartScreen: View {
    let metric: ChartMetric

    var body: some View {
        ScrollView {
            MetricChartView(metric: metric)
                .padding(NL.Spacing.l)
        }
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
