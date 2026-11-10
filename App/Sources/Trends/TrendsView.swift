import Core
import DesignSystem
import Persistence
import SwiftUI

/// "Trends": the maintenance estimate and weekly check-in, the history calendar, charts and the weekly report.
struct TrendsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var snapshot: ExpenditureSnapshot?
    @State private var showCheckIn = false
    @State private var explaining: CheckInFact?

    var body: some View {
        NavigationStack {
            List {
                maintenanceSection
                Section {
                    NavigationLink { HistoryCalendarView() } label: { Label("History calendar", systemImage: "calendar") }
                    NavigationLink { WeeklyReportView() } label: { Label("Weekly report", systemImage: "doc.text.below.ecg") }
                }
                Section("Charts") {
                    ForEach(ChartMetric.allCases) { metric in
                        NavigationLink { MetricChartScreen(metric: metric) } label: { Label(metric.title, systemImage: metric.systemImage) }
                    }
                }
                Section {
                    NavigationLink { CheckInHistoryView() } label: { Label("Check-in history", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { CheckInSettingsView() } label: { Label("Check-in day & reminder", systemImage: "bell") }
                }
            }
            .navigationTitle("Trends")
            .refreshable { reload() }
            .sheet(isPresented: $showCheckIn, onDismiss: reload) { CheckInView() }
            .sheet(item: $explaining) { ExplanationSheet(fact: $0) }
        }
        .task(id: TrendsKey(
            today: environment.today, generation: environment.dataGeneration, tab: environment.selectedTab,
            synced: environment.healthSync?.lastSyncedAt,
        )) { reload() }
    }

    private struct TrendsKey: Hashable {
        var today: LocalDay
        var generation: Int
        var tab: AppTab
        /// Weights arrive with Health syncs.
        var synced: Date?
    }

    private var maintenanceSection: some View {
        Section {
            if let snapshot {
                switch snapshot.estimate {
                case let .success(estimate):
                    Button {
                        explaining = CheckInFact(
                            kind: .estimate, title: "Estimated maintenance", value: environment.energyUnit.format(estimate.kcal),
                            explanation: CheckInModel.estimateExplanation(estimate, unit: environment.energyUnit),
                        )
                    } label: {
                        MaintenanceCard(estimate: estimate, unit: environment.energyUnit)
                    }
                    .buttonStyle(.plain)
                case let .failure(reason):
                    VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                        Text("Estimated maintenance").font(.subheadline).foregroundStyle(.secondary)
                        Text("Not enough data yet").font(NL.Typography.number)
                        Text(reason.explanation).font(.footnote).foregroundStyle(.secondary)
                        if let baseline = snapshot.baselineKcal {
                            Text(
                                "\(snapshot.baselineIsMeasured ? "Health energy average" : "Formula estimate") meanwhile: "
                                    + environment.energyUnit.format(baseline),
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button { showCheckIn = true } label: {
                    HStack {
                        Label("Weekly check-in", systemImage: "checkmark.circle")
                        Spacer()
                        if snapshot.isCheckInDue, snapshot.kcal != nil {
                            Text("Due").font(.caption.weight(.semibold)).padding(.horizontal, NL.Spacing.s).padding(
                                .vertical,
                                NL.Spacing.xxs,
                            )
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            } else {
                ProgressView()
            }
        } footer: {
            Text("Estimated from what you logged and how your weight trend moved over the last \(AdaptiveTDEE.windowDays) days.")
        }
    }

    private func reload() {
        snapshot = try? Expenditure.snapshot(environment: environment)
    }
}

/// "Estimated maintenance 2,480 kcal · Medium confidence".
struct MaintenanceCard: View {
    let estimate: TDEEEstimate
    let unit: EnergyUnit

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xs) {
            Text("Estimated maintenance").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(unit.format(estimate.kcal)).font(NL.Typography.largeNumber).monospacedDigit()
                Spacer()
                ConfidenceBadge(confidence: estimate.confidence)
            }
            Text(
                "\(estimate.loggedDays) of \(estimate.windowDays) days logged · trend "
                    + "\(DashboardFormat.kgChange(estimate.weeklyChangeKg)) / week",
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows how this was computed")
    }
}

struct ConfidenceBadge: View {
    let confidence: TDEEConfidence

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < level ? Color.accentColor : NL.Palette.track)
                    .frame(width: 6, height: CGFloat(8 + index * 4))
            }
            Text(confidence.title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(confidence.title)
    }

    private var level: Int {
        switch confidence {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
}
