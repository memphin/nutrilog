import Core
import DesignSystem
import SwiftUI

/// Loads a week's `WeeklyReport` from the same `DayStats` the charts use.
@MainActor
enum WeeklyReportLoader {
    static func load(weekStart: LocalDay, environment: AppEnvironment) throws -> WeeklyReport {
        let end = weekStart.adding(days: 6)
        // One extra day in front for the trend before the week.
        let stats = try StatsLoader.load(weekStart.previous ... end, environment: environment)
        let snapshot = try? Expenditure.snapshot(environment: environment)
        // Today is still being logged: it counts once it is over or marked as fully logged (as in the charts).
        return WeeklyReport(
            days: IntakeStats.finished(Array(stats.dropFirst()), today: environment.today), trendBefore: stats.first?.trendKg,
            expenditureKcal: expenditure(for: end, snapshot: snapshot, environment: environment),
        )
    }

    /// The maintenance estimate that applied to the week ending on `end`: for the current or just-finished week the
    /// live estimate; for older weeks the check-in made in the week after (or the latest before it); else the
    /// baseline (measured Health energy or the formula).
    static func expenditure(for end: LocalDay, snapshot: ExpenditureSnapshot?, environment: AppEnvironment) -> Double? {
        if end >= environment.today.previous, let live = snapshot?.kcal {
            return live
        }
        if let record = try? environment.checkIns?.latest(onOrBefore: end.adding(days: 7)) {
            return record.tdeeKcal
        }
        return snapshot?.kcal ?? snapshot?.baselineKcal
    }
}

/// Weekly report for any past week, shareable as an image rendered on the device (FR-52, backlog #39).
struct WeeklyReportView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var weekStart: LocalDay?
    @State private var report: WeeklyReport?
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    private var currentWeek: LocalDay {
        environment.today.weekStart(firstWeekday: Calendar.current.firstWeekday)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NL.Spacing.l) {
                weekPicker
                if let report {
                    WeeklyReportCard(report: report, unit: environment.energyUnit, today: environment.today)
                    if let shareURL {
                        ShareLink(item: shareURL, preview: SharePreview("Vitalion weekly report")) {
                            Label("Share as image", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView().frame(minHeight: 200)
                }
            }
            .padding(NL.Spacing.l)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Weekly report")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: Key(
            week: weekStart ?? currentWeek, generation: environment.dataGeneration, unit: environment.energyUnit,
            synced: environment.healthSync?.lastSyncedAt,
        )) { load() }
        .alert("Weekly report", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private struct Key: Hashable {
        var week: LocalDay
        var generation: Int
        var unit: EnergyUnit
        var synced: Date?
    }

    private var weekPicker: some View {
        let week = weekStart ?? currentWeek
        return HStack {
            Button("Previous week", systemImage: "chevron.left") { weekStart = week.adding(days: -7) }
                .labelStyle(.iconOnly)
            Spacer()
            VStack {
                Text(Self.title(week)).font(.headline)
                if week == currentWeek {
                    Text("This week so far").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Next week", systemImage: "chevron.right") { weekStart = week.adding(days: 7) }
                .labelStyle(.iconOnly)
                .disabled(week >= currentWeek)
        }
    }

    /// "2 – 8 Nov 2026".
    static func title(_ week: LocalDay) -> String {
        let end = week.adding(days: 6)
        let last = end.startDate().formatted(.dateTime.day().month(.abbreviated).year())
        let first = week.month == end.month
            ? "\(week.day)"
            : week.startDate().formatted(.dateTime.day().month(.abbreviated))
        return "\(first) – \(last)"
    }

    private func load() {
        let week = weekStart ?? currentWeek
        do {
            let loaded = try WeeklyReportLoader.load(weekStart: week, environment: environment)
            report = loaded
            shareURL = Self.renderImage(loaded, unit: environment.energyUnit, today: environment.today)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders the card to a PNG in the temporary folder (nothing leaves the device until the user shares it).
    static func renderImage(_ report: WeeklyReport, unit: EnergyUnit, today: LocalDay) -> URL? {
        let card = WeeklyReportCard(report: report, unit: unit, today: today, showsBranding: true)
            .frame(width: 390)
            .padding(NL.Spacing.l)
            .background(Color(.systemGroupedBackground))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitalion-week-\(report.start.isoString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// The report itself; also what the shared image shows.
struct WeeklyReportCard: View {
    let report: WeeklyReport
    let unit: EnergyUnit
    let today: LocalDay
    var showsBranding = false

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.l) {
            if showsBranding {
                HStack {
                    Text("Vitalion").font(.headline)
                    Spacer()
                    Text(WeeklyReportView.title(report.start)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            section("Intake") {
                if let intake = report.averageIntake {
                    row("Average", unit.format(intake.kcal), detail: report.averageTargetKcal.map { "target \(unit.format($0))" })
                    row("Protein · Carbs · Fat", "\(grams(intake.proteinG)) · \(grams(intake.carbsG)) · \(grams(intake.fatG))")
                    row("Days logged", "\(report.loggedDays) of \(report.days.count)")
                } else {
                    Text("Nothing logged this week.").foregroundStyle(.secondary)
                }
                adherenceStrip
            }
            if report.bestDay != nil {
                section("Days") {
                    if let best = report.bestDay {
                        row("Closest to target", dayName(best.day), detail: difference(best))
                    }
                    if let worst = report.worstDay {
                        row("Furthest from target", dayName(worst.day), detail: difference(worst))
                    }
                }
            }
            section("Energy balance") {
                if let expenditure = report.expenditureKcal {
                    row("Estimated expenditure", unit.format(expenditure))
                    if let balance = report.balanceKcal {
                        row(balance < 0 ? "Average deficit" : "Average surplus", unit.format(abs(balance)), detail: "per day")
                    }
                } else {
                    Text("No expenditure estimate yet.").foregroundStyle(.secondary)
                }
                if let change = report.trendChangeKg, let end = report.trendEndKg {
                    row("Weight trend", DashboardFormat.kgChange(change), detail: "now \(DashboardFormat.kg(end))")
                } else {
                    row("Weight trend", "—")
                }
            }
            if report.averageSteps != nil || report.averageSleepMin != nil || report.averageWaterMl != nil {
                section("Activity & recovery") {
                    if let steps = report.averageSteps {
                        row("Steps", "\(steps.formatted(.number.precision(.fractionLength(0))))", detail: "per day")
                    }
                    if let sleep = report.averageSleepMin {
                        row("Sleep", DashboardFormat.duration(Int(sleep.rounded())), detail: "per night")
                    }
                    if let water = report.averageWaterMl {
                        row("Water", DashboardFormat.ml(water), detail: "per day")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var adherenceStrip: some View {
        HStack(spacing: 4) {
            ForEach(report.days, id: \.day) { day in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(day.day > today ? Color.clear : day.adherence.color.opacity(day.adherence == .notLogged ? 1 : 0.7))
                        .frame(height: 22)
                    Text(day.day.startDate().formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Days on target: \(report.days.count(where: { $0.adherence == .onTarget })) of \(report.days.count)")
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(NL.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: NL.Radius.m))
    }

    private func row(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(NL.Typography.smallNumber).monospacedDigit()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func grams(_ value: Double) -> String {
        "\(Int(value.rounded())) g"
    }

    private func dayName(_ day: LocalDay) -> String {
        day.startDate().formatted(.dateTime.weekday(.wide))
    }

    private func difference(_ day: WeeklyReport.RankedDay) -> String {
        let value = unit.format(abs(day.difference))
        return abs(day.difference) < 0.5 ? "on target" : "\(value) \(day.difference < 0 ? "under" : "over")"
    }
}
