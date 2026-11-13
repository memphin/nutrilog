import Charts
import Core
import DesignSystem
import HealthKitClient
import SwiftUI

/// "Training" tab: the workouts Apple Health has, next to this week's eating. Training (strength, running, …) and
/// everyday activity (walks) are kept apart: only training counts as a session and makes a day a training day; which
/// kinds are which is set in Settings → Training days. Nothing is logged here.
struct TrainingView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: TrainingModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    TrainingContent(model: model)
                } else {
                    Color(.systemGroupedBackground).ignoresSafeArea()
                }
            }
            .navigationTitle("Training")
        }
        .task {
            if model == nil {
                model = TrainingModel(environment: environment)
            }
        }
    }
}

private struct TrainingContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: TrainingModel
    @State private var showOnboarding = false

    var body: some View {
        ScrollView {
            VStack(spacing: NL.Spacing.l) {
                switch model.access {
                case .unavailable:
                    EmptyStateView(String(localized: "Apple Health isn't available on this device."), systemImage: "dumbbell")
                case .notConnected:
                    EmptyStateView(
                        String(localized: "Workouts come from Apple Health"),
                        systemImage: "dumbbell",
                        message: String(localized: "Connect Apple Health to see the workouts your watch and training apps record."),
                    )
                    Button("Connect Apple Health") { showOnboarding = true }
                        .buttonStyle(.borderedProminent)
                case .needsWorkoutAccess:
                    AllowWorkoutsCard { await model.allowWorkouts() }
                    overview
                case .connected:
                    overview
                }
            }
            .padding(.horizontal, NL.Spacing.l)
            .padding(.bottom, NL.Spacing.xxl)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TrainingDaysSettingsView()
                } label: {
                    Label("Training days", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            HealthOnboardingView()
        }
        .errorAlert($model.errorMessage)
        .task(id: environment.today) { await model.observe() }
        .task(id: FuelKey(
            today: environment.today, generation: environment.dataGeneration, unit: environment.energyUnit,
            synced: environment.healthSync?.lastSyncedAt,
        )) { model.reloadFuel() }
        .onAppear { model.reloadFuel() } // the diary may have changed on another tab
    }

    /// What this week's fuel is re-read on: a new day, an import, the energy unit, Health syncs (weights).
    private struct FuelKey: Hashable {
        var today: LocalDay
        var generation: Int
        var unit: EnergyUnit
        var synced: Date?
    }

    @ViewBuilder private var overview: some View {
        if let overview = model.overview, overview.hasWorkouts {
            WeekCard(week: overview.week, today: overview.today)
            WeeksChartCard(weeks: overview.weeklySessions)
            FuelCard(fuel: model.fuel, unit: model.energyUnit)
            SessionsCard(sessions: overview.recentSessions, today: overview.today, unit: model.energyUnit)
            if !overview.activity.workouts.isEmpty {
                ActivityCard(activity: overview.activity, today: overview.today, unit: model.energyUnit)
            }
        } else if model.overview == nil || model.isSyncing {
            ProgressView("Reading Apple Health…").frame(minHeight: 200)
        } else if model.access == .connected {
            EmptyStateView(
                String(localized: "No workouts yet"),
                systemImage: "dumbbell",
                message: String(localized: """
                Workouts recorded in Apple Health in the last 90 days show up here. If you have some, check \
                \(HealthKitClient.permissionsPath).
                """),
            )
        }
    }
}

// MARK: - Cards

/// A titled card, like the weekly report's sections.
private struct TrainingCard<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(NL.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: NL.Radius.m))
    }
}

/// For users who connected Health before Vitalion read workouts.
private struct AllowWorkoutsCard: View {
    let allow: () async -> Void
    @State private var isAsking = false

    var body: some View {
        TrainingCard(title: String(localized: "Apple Health")) {
            Text("Vitalion can now show the workouts your watch and training apps record. Apple Health asks you once.")
                .font(.subheadline)
            Button("Allow workouts") {
                isAsking = true
                Task {
                    await allow()
                    isAsking = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAsking)
        }
    }
}

/// This week: days trained against days planned, the time trained, and a mark per day.
private struct WeekCard: View {
    let week: TrainingWeek
    let today: LocalDay

    var body: some View {
        TrainingCard(title: String(localized: "This week")) {
            Text(TrainingText.weekHeadline(week)).font(NL.Typography.number).monospacedDigit()
            HStack(spacing: 0) {
                ForEach(week.days) { day in
                    VStack(spacing: NL.Spacing.xs) {
                        Text(day.day.startDate().formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(day.day == today ? .bold : .regular))
                            .foregroundStyle(day.day == today ? .primary : .secondary)
                        DayMark(day: day).opacity(day.day > today ? 0.5 : 1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, NL.Spacing.xs)
            HStack(spacing: NL.Spacing.m) {
                legend(String(localized: "Trained", comment: "Legend: a day with a training workout"), isTrained: true)
                legend(String(localized: "Planned", comment: "Legend: a planned training day without a workout"), isTrained: false)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week")
        .accessibilityValue(TrainingText.weekSpoken(week))
    }

    private func legend(_ title: String, isTrained: Bool) -> some View {
        HStack(spacing: NL.Spacing.xs) {
            Group {
                if isTrained {
                    Circle().fill(Color.accentColor)
                } else {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .frame(width: 9, height: 9)
            Text(title)
        }
    }
}

/// A day of the week: filled when trained, outlined when planned, a dot otherwise.
private struct DayMark: View {
    let day: TrainingWeek.Day

    var body: some View {
        ZStack {
            if day.isTrained {
                Circle().fill(Color.accentColor)
            } else if day.isPlanned {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
            } else {
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Training sessions per week for the last weeks; the current week stands out.
private struct WeeksChartCard: View {
    let weeks: [TrainingOverview.WeekCount]

    private var top: Int {
        max(weeks.map(\.sessions).max() ?? 0, 1)
    }

    /// The finished weeks' mean (the current week is still running).
    private var average: Double? {
        let finished = weeks.dropLast()
        return finished.isEmpty ? nil : Double(finished.reduce(0) { $0 + $1.sessions }) / Double(finished.count)
    }

    var body: some View {
        TrainingCard(title: String(localized: "Last \(weeks.count) weeks"), detail: average.map(TrainingText.perWeek)) {
            Chart(weeks) { week in
                BarMark(x: .value("Week", week.weekStart.isoString), y: .value("Workouts", week.sessions), width: .ratio(0.7))
                    .foregroundStyle(week.id == weeks.last?.id ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0 ... top)
            .chartYAxis {
                AxisMarks(values: Array(stride(from: 0, through: top, by: TrainingText.axisStep(top: top)))) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 96)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last \(weeks.count) weeks")
        .accessibilityValue(average.map(TrainingText.perWeek) ?? "")
    }
}

/// This week's eating: average intake against the target, protein per kg and the weight trend. Opens the weekly report.
private struct FuelCard: View {
    let fuel: TrainingFuel?
    let unit: EnergyUnit

    var body: some View {
        NavigationLink {
            WeeklyReportView()
        } label: {
            TrainingCard(title: String(localized: "This week's fuel")) {
                if let fuel, let kcal = fuel.averageKcal {
                    row(
                        "Average intake",
                        unit.format(kcal),
                        detail: fuel.averageTargetKcal.map { String(localized: "target \(unit.format($0))") },
                    )
                    if let protein = fuel.proteinG {
                        if let perKg = fuel.proteinPerKg {
                            row(
                                "Protein",
                                TrainingText.gramsPerKg(perKg),
                                detail: String(localized: "\(DisplayRounding.whole(protein)) g a day"),
                            )
                        } else {
                            row("Protein", "\(DisplayRounding.whole(protein)) g", detail: String(localized: "per day"))
                        }
                    }
                } else {
                    Text("Nothing logged this week.").foregroundStyle(.secondary)
                }
                row("Weight trend", fuel?.trendChangeKg.map(Format.kgChange) ?? "—")
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the weekly report")
    }

    private func row(_ title: LocalizedStringKey, _ value: String, detail: String? = nil) -> some View {
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
}

/// The training sessions of the last four weeks, newest first.
private struct SessionsCard: View {
    let sessions: [HealthWorkout]
    let today: LocalDay
    let unit: EnergyUnit

    var body: some View {
        TrainingCard(title: String(localized: "Workouts"), detail: String(localized: "Last 4 weeks")) {
            if sessions.isEmpty {
                Text("No training in the last 4 weeks.").foregroundStyle(.secondary)
            } else {
                WorkoutRows(workouts: sessions, today: today, unit: unit)
            }
        }
    }
}

/// This week's workouts that don't count as training: walks, unless the user chose otherwise.
private struct ActivityCard: View {
    let activity: ActivitySummary
    let today: LocalDay
    let unit: EnergyUnit

    var body: some View {
        TrainingCard(
            title: activity.isOnlyWalks ? String(localized: "Walks") : String(localized: "Other activity"),
            detail: TrainingText.activitySummary(activity),
        ) {
            WorkoutRows(workouts: activity.workouts, today: today, unit: unit)
        }
    }
}

private struct WorkoutRows: View {
    let workouts: [HealthWorkout]
    let today: LocalDay
    let unit: EnergyUnit

    var body: some View {
        VStack(spacing: NL.Spacing.s) {
            ForEach(workouts) { workout in
                HStack(spacing: NL.Spacing.m) {
                    Image(systemName: workout.kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(workout.kind.title)
                        Text(Format.day(workout.day, today: today)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Format.duration(minutes: workout.minutes)).font(NL.Typography.smallNumber).monospacedDigit()
                        if let extras = TrainingText.extras(workout, unit: unit) {
                            Text(extras).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Texts

/// Texts of the Training tab.
enum TrainingText {
    /// "3 of 4 planned · 3 h 10 min" with planned training days this week; "3 workouts · 3 h 10 min" without a plan.
    static func weekHeadline(_ week: TrainingWeek) -> String {
        let count = week.plannedDays > 0
            ? String(
                localized: "\(week.trainedDays) of \(week.plannedDays) planned",
                comment: "Days trained out of the planned training days",
            )
            : String(localized: "\(week.sessions.count) workouts")
        guard week.totalMinutes > 0 else { return count }
        return "\(count) · \(Format.duration(minutes: week.totalMinutes))"
    }

    /// The headline for VoiceOver, with the days: "3 of 4 planned · 3 h 10 min, trained on Monday, Wednesday, Friday".
    static func weekSpoken(_ week: TrainingWeek) -> String {
        let trained = week.days.filter(\.isTrained).map { $0.day.startDate().formatted(.dateTime.weekday(.wide)) }
        guard !trained.isEmpty else { return weekHeadline(week) }
        return "\(weekHeadline(week)), \(String(localized: "trained on \(trained.formatted(.list(type: .and)))"))"
    }

    /// "410 kcal · 6.8 km": what a workout has besides its duration; nil when it has neither.
    static func extras(_ workout: HealthWorkout, unit: EnergyUnit) -> String? {
        var parts: [String] = []
        if let kcal = workout.activeKcal, kcal >= 1 {
            parts.append(unit.format(kcal))
        }
        if let meters = workout.distanceM, meters >= 50 {
            parts.append(km(meters))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4 this week · 2 h 45 min · 13.2 km".
    static func activitySummary(_ activity: ActivitySummary) -> String {
        var parts = [String(localized: "\(activity.workouts.count) this week", comment: "Number of walks or other activities this week")]
        if activity.totalMinutes > 0 {
            parts.append(Format.duration(minutes: activity.totalMinutes))
        }
        if let meters = activity.distanceM, meters >= 50 {
            parts.append(km(meters))
        }
        return parts.joined(separator: " · ")
    }

    /// "6.8 km" (the app is metric).
    static func km(_ meters: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\((meters / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale))) km"
    }

    /// "1.7 g/kg".
    static func gramsPerKg(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(localized: "\(number) g/kg", comment: "Protein per kilogram of body weight, e.g. “1.7 g/kg”")
    }

    /// "3.2 a week": the mean number of training sessions per week.
    static func perWeek(_ average: Double) -> String {
        let number = average.formatted(.number.precision(.fractionLength(0 ... 1)))
        return String(localized: "\(number) a week", comment: "Average training sessions per week, e.g. “3.2 a week”")
    }

    /// The distance between the chart's Y axis lines, so there are at most about four.
    static func axisStep(top: Int) -> Int {
        max(1, Int((Double(top) / 4).rounded(.up)))
    }
}

extension WorkoutKind {
    /// The SF Symbol of the kind.
    var systemImage: String {
        switch self {
        case .badminton: "figure.badminton"
        case .basketball: "figure.basketball"
        case .boxing: "figure.boxing"
        case .climbing: "figure.climbing"
        case .crossTraining: "figure.cross.training"
        case .cycling: "figure.outdoor.cycle"
        case .elliptical: "figure.elliptical"
        case .functionalStrength: "figure.strengthtraining.functional"
        case .golf: "figure.golf"
        case .handball: "figure.handball"
        case .hiking: "figure.hiking"
        case .martialArts: "figure.martial.arts"
        case .mindAndBody: "figure.mind.and.body"
        case .rowing: "figure.rower"
        case .running: "figure.run"
        case .skating: "figure.skating"
        case .soccer: "figure.soccer"
        case .squash: "figure.squash"
        case .stairStepper: "figure.stair.stepper"
        case .swimming: "figure.pool.swim"
        case .tableTennis: "figure.table.tennis"
        case .tennis: "figure.tennis"
        case .strength: "figure.strengthtraining.traditional"
        case .volleyball: "figure.volleyball"
        case .walking: "figure.walk"
        case .yoga: "figure.yoga"
        case .coreTraining: "figure.core.training"
        case .crossCountrySkiing: "figure.skiing.crosscountry"
        case .downhillSkiing: "figure.skiing.downhill"
        case .flexibility: "figure.flexibility"
        case .highIntensityIntervals: "figure.highintensity.intervaltraining"
        case .jumpRope: "figure.jumprope"
        case .kickboxing: "figure.kickboxing"
        case .pilates: "figure.pilates"
        case .snowboarding: "figure.snowboarding"
        case .stairs: "figure.stairs"
        case .mixedCardio, .other: "figure.mixed.cardio"
        case .dance: "figure.dance"
        case .cooldown: "figure.cooldown"
        case .multisport: "figure.open.water.swim"
        }
    }
}

#if DEBUG
    #Preview {
        TrainingView().environment(AppEnvironment.preview(sampleData: true))
    }
#endif
