import Charts
import Core
import DesignSystem
import Persistence
import SwiftUI

/// The caffeine tile's detail: the curve from the morning into the night with now, bedtime and the sleep-safe line;
/// tonight's outlook; today's drinks (quick-adds deletable with undo, diary foods read-only); adding a drink, also at
/// an earlier time; the last 14 days' totals; how the estimate works.
struct CaffeineDetailView: View {
    @Bindable var model: DashboardModel
    @State private var history: [TileHistoryRow] = []
    @State private var showsEntrySheet = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content(model.caffeineStatus(at: model.now))
        }
        .navigationTitle("Caffeine")
        .task(id: model.data) { history = model.history(for: .caffeine) }
        .sheet(isPresented: $showsEntrySheet) { CaffeineEntrySheet(model: model) }
        .undoToast(model.undo)
    }

    private func content(_ status: CaffeineStatus) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.xs) {
                        Text(CaffeineStatus.mgNumber(status.mgNow))
                            .font(NL.Typography.largeNumber).monospacedDigit().contentTransition(.numericText())
                            .foregroundStyle(GoalColor.color(status.band))
                        Text("mg now").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(status.outlookText()).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                CaffeineCurveChart(status: status)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: NL.Spacing.m, leading: NL.Spacing.l, bottom: NL.Spacing.m, trailing: NL.Spacing.l))
            }

            Section("Tonight") {
                LabeledContent("At bedtime (\(CaffeineStatus.time(status.bedtime)))", value: CaffeineStatus.mg(status.mgAtBedtime))
                LabeledContent("Below \(CaffeineStatus.mg(status.thresholdMg)) from", value: safeText(status))
                LabeledContent("Today") {
                    Text("\(CaffeineStatus.mgNumber(status.todayTotalMg)) of \(CaffeineStatus.mg(status.dailyLimitMg))")
                        .foregroundStyle(status.isOverDailyLimit ? GoalColor.missed : .secondary)
                }
            }
            .monospacedDigit()

            Section {
                Menu {
                    ForEach(CaffeineDrink.all) { drink in
                        Button {
                            model.addCaffeine(drink: drink)
                        } label: {
                            Label("\(drink.name) · \(CaffeineStatus.mg(drink.mg))", systemImage: drink.symbolName)
                        }
                    }
                    Divider()
                    Button("Other amount or time…", systemImage: "clock") { showsEntrySheet = true }
                } label: {
                    Label("Add drink", systemImage: "plus")
                }
            }

            todaysIntakes

            Section {
                ForEach(history) { row in
                    historyRow(row)
                }
            } header: {
                Text("Last \(TileHistory.days) days")
            }

            Section {
                NavigationLink("Caffeine settings") { CaffeineSettingsView() }
            } footer: {
                Text(CaffeineStatus.explanation(halfLifeHours: status.halfLifeHours))
            }
        }
    }

    @ViewBuilder private var todaysIntakes: some View {
        let rows = model.todaysCaffeine
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    LabeledContent {
                        Text(CaffeineStatus.mg(row.mg)).monospacedDigit()
                    } label: {
                        Text(row.name)
                        let time = CaffeineStatus.time(row.at)
                        Text(row.source == .diary ? String(localized: "\(time) · from the diary") : time)
                    }
                    .swipeActions {
                        if case let .quickAdd(entry) = row.source {
                            Button("Delete", role: .destructive) { model.deleteCaffeine(entry) }
                        }
                    }
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Foods with caffeine come from the diary; change or delete them there.")
            }
        }
    }

    private func historyRow(_ row: TileHistoryRow) -> some View {
        let style: AnyShapeStyle = if row.value == nil {
            AnyShapeStyle(.tertiary)
        } else if row.detail != nil {
            AnyShapeStyle(GoalColor.missed) // over the daily limit
        } else {
            AnyShapeStyle(.primary)
        }
        let spoken: [String?] = [row.value ?? String(localized: "none", comment: "No caffeine that day (VoiceOver)"), row.detail]
        return LabeledContent(Format.day(row.day, today: model.data.today)) {
            Text(row.value ?? "—").monospacedDigit().foregroundStyle(style)
        }
        .accessibilityValue(spoken.compactMap(\.self).joined(separator: ", "))
    }

    private func safeText(_ status: CaffeineStatus) -> String {
        if status.outlook == .safeNow {
            return String(localized: "Now")
        }
        return status.safeAt.map(CaffeineStatus.time) ?? String(localized: "Not within 2 days")
    }
}

// MARK: - Chart

/// The curve with axes: hours along the bottom, mg on the side, rules at now and bedtime, the dashed sleep-safe line.
private struct CaffeineCurveChart: View {
    let status: CaffeineStatus

    var body: some View {
        let window = status.detailWindow
        let points = status.curve(in: window, step: 300)
        let top = max(points.map(\.mg).max() ?? 0, status.thresholdMg * 1.5) * 1.1
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            chart(points: points, window: window, top: top)
            legend
        }
    }

    /// Under the chart, not on it: inside the plot the label met the now or bedtime rule wherever it was placed.
    private var legend: some View {
        HStack(spacing: NL.Spacing.m) {
            HStack(spacing: NL.Spacing.xs) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 16, y: 1))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: 16, height: 2)
                Text("Sleep-safe \(CaffeineStatus.mg(status.thresholdMg))")
            }
            HStack(spacing: NL.Spacing.xs) {
                Image(systemName: "moon.fill").foregroundStyle(.indigo)
                Text("Bedtime \(CaffeineStatus.time(status.bedtime))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true) // the chart's accessibility value already says both
    }

    private func chart(points: [CaffeinePoint], window: ClosedRange<Date>, top: Double) -> some View {
        Chart {
            ForEach(points, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                    .foregroundStyle(LinearGradient(
                        colors: [NL.Palette.caffeine.opacity(0.35), NL.Palette.caffeine.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom,
                    ))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                    .foregroundStyle(NL.Palette.caffeine)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            RuleMark(y: .value("Sleep-safe", status.thresholdMg))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if window.contains(status.bedtime) {
                RuleMark(x: .value("Bedtime", status.bedtime))
                    .foregroundStyle(Color.indigo.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Image(systemName: "moon.fill").font(.caption2).foregroundStyle(.indigo)
                    }
            }
            RuleMark(x: .value("Now", status.now))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            PointMark(x: .value("Time", status.now), y: .value("Caffeine", status.mgNow))
                .foregroundStyle(GoalColor.color(status.band))
                .symbolSize(60)
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0 ... top)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let mg = value.as(Double.self) {
                        Text("\(CaffeineStatus.mgNumber(mg))")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caffeine curve")
        .accessibilityValue(accessibilityValue)
    }

    /// "85 milligrams now, about 40 at bedtime, 23:00. Sleep-safe now": whole milligrams as integers, so
    /// the catalog can pick the plural form.
    private var accessibilityValue: String {
        let now = Int(max(status.mgNow, 0).rounded(.toNearestOrEven))
        let bedtime = Int(max(status.mgAtBedtime, 0).rounded(.toNearestOrEven))
        let time = CaffeineStatus.time(status.bedtime)
        let outlook = status.outlookText()
        return String(localized: "\(now) milligrams now, about \(bedtime) at bedtime, \(time). \(outlook)")
    }
}

// MARK: - Entry sheet

/// A drink at another time, or a custom amount: preset or custom, mg, time (since yesterday morning).
struct CaffeineEntrySheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var drinkID: String? = CaffeineDrink.espresso.id
    @State private var mgText = Format.field(CaffeineDrink.espresso.mg)
    @State private var name = ""
    @State private var mlText = ""
    @State private var time = Date()

    static let maximumMg = 1000.0

    private var mg: Double? {
        Format.number(mgText).flatMap { $0 > 0 && $0 <= Self.maximumMg ? $0 : nil }
    }

    /// The optional "Volume (ml)" field: nil when empty, not a number, or not positive.
    static func volumeMl(_ text: String) -> Double? {
        Format.number(text).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        let range = model.data.today.adding(days: -1).startDate() ... max(model.now, time)
        NavigationStack {
            Form {
                Section {
                    Picker("Drink", selection: $drinkID) {
                        ForEach(CaffeineDrink.all) { drink in
                            Text(drink.name).tag(Optional(drink.id))
                        }
                        Text("Custom").tag(String?.none)
                    }
                    if drinkID == nil {
                        TextField("Name (optional)", text: $name)
                    }
                    LabeledContent("Caffeine") {
                        HStack(spacing: NL.Spacing.xs) {
                            TextField("mg", text: $mgText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("mg").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Volume (ml)") {
                        TextField("Optional", text: $mlText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Time", selection: $time, in: range, displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("Set an earlier time for a drink you had before. Amounts of presets are typical values; adjust them to your drink.")
                }
            }
            .navigationTitle("Add caffeine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(mg == nil)
                }
            }
            .onChange(of: drinkID) {
                if let drink = drinkID.flatMap(CaffeineDrink.preset(id:)) {
                    mgText = Format.field(drink.mg)
                }
            }
            .onAppear { time = model.now }
        }
    }

    private func add() {
        guard let mg else { return }
        let preset = drinkID.flatMap(CaffeineDrink.preset(id:))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.addCaffeine(
            mg: mg, at: min(time, model.now), drinkID: preset?.id, name: preset?.name ?? (trimmed.isEmpty ? nil : trimmed),
            ml: Self.volumeMl(mlText),
        )
        dismiss()
    }
}
