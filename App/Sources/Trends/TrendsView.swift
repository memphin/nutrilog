import Core
import DesignSystem
import Persistence
import SwiftUI

/// "Trends": the maintenance estimate and weekly check-in, the history calendar and the weekly report. Charts open from
/// the Today tiles.
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
                            kind: .estimate, title: String(localized: "Estimated maintenance"),
                            value: environment.energyUnit.format(estimate.kcal),
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
                            let baselineText = environment.energyUnit.format(baseline)
                            Group {
                                if snapshot.baselineIsMeasured {
                                    Text("Health energy average meanwhile: \(baselineText)")
                                } else {
                                    Text("Formula estimate meanwhile: \(baselineText)")
                                }
                            }
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
            Text("Estimated from what you logged and how your weight moved over the last \(AdaptiveTDEE.windowDays) days.")
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
            Text(Self.summary(estimate))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows how this was computed")
    }

    /// "12 of 14 days logged · trend −0.3 kg / week"; the weight change is named after how it was measured
    /// (`TDEEEstimate.resolvedWeightMethod`, explained in full by `TDEEWeightMethod.explanation` in the sheet):
    /// "weigh-ins −0.3 kg / week" when it comes from a straight line through the weigh-ins.
    static func summary(_ estimate: TDEEEstimate) -> String {
        let change = Format.kgChange(estimate.weeklyChangeKg)
        return switch estimate.resolvedWeightMethod {
        case .trend: String(localized: "\(estimate.loggedDays) of \(estimate.windowDays) days logged · trend \(change) / week")
        case .weighInLine: String(localized: "\(estimate.loggedDays) of \(estimate.windowDays) days logged · weigh-ins \(change) / week")
        }
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
