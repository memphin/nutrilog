import Core
import DesignSystem
import Persistence
import SwiftUI

/// The weekly check-in sheet: how the week went, the maintenance estimate and a proposed calorie target that the
/// user accepts, changes or skips (SPEC §5.4.1 steps 6–7, backlog #35).
struct CheckInView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: CheckInModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    CheckInContent(model: model) { dismiss() }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Weekly check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear {
            if model == nil {
                model = CheckInModel(environment: environment)
            }
        }
        // Weights arrive with Health syncs: recompute when one finishes while the sheet is open.
        .onChange(of: environment.healthSync?.lastSyncedAt) { model?.reload() }
    }
}

private struct CheckInContent: View {
    @Bindable var model: CheckInModel
    let onDone: () -> Void
    @State private var explaining: CheckInFact?
    @State private var showDays = false
    @State private var showEdit = false
    @State private var editText = ""

    var body: some View {
        List {
            if let snapshot = model.snapshot {
                switch snapshot.estimate {
                case let .success(estimate):
                    estimateSections(estimate, snapshot: snapshot)
                case let .failure(reason):
                    Section {
                        EmptyStateView(
                            String(localized: "Not enough data yet"), systemImage: "chart.line.uptrend.xyaxis",
                            message: reason.explanation,
                        )
                    } footer: {
                        Text("""
                        The estimate compares what you ate with how your weight trend moved over the last \
                        \(AdaptiveTDEE.windowDays) days. Log your food and weigh in most days and it appears by itself.
                        """)
                    }
                }
            }
        }
        .sheet(item: $explaining) { fact in
            ExplanationSheet(fact: fact)
        }
        .sheet(isPresented: $showDays) {
            if let estimate = model.estimate {
                NavigationStack { EstimateDaysView(estimate: estimate, unit: model.unit) }
            }
        }
        .alert("Set my own target", isPresented: $showEdit) {
            TextField("kcal per day", text: $editText).keyboardType(.numberPad)
            Button("Apply") {
                if let kcal = Format.number(editText), model.applyEdited(kcal: kcal) {
                    onDone()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daily calorie target from today, in kcal.")
        }
        .alert("Check-in", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private func estimateSections(_ estimate: TDEEEstimate, snapshot: ExpenditureSnapshot) -> some View {
        Section {
            ForEach(model.facts) { fact in
                FactRow(fact: fact) { explaining = fact }
            }
        } header: {
            Text("This week")
        } footer: {
            Text("Tap any number to see how it was computed.")
        }

        if estimate.underLoggingSuspected {
            Section {
                Label {
                    Text("""
                    Your logged intake looks low for how your weight moved. If some meals weren't logged, the estimate \
                    is too low — your target is not lowered because of it.
                    """)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.footnote)
            }
        }

        Section {
            Button("How was this computed?", systemImage: "list.bullet.rectangle") { showDays = true }
        }

        if let proposal = snapshot.proposal {
            Section {
                Button {
                    if model.accept() {
                        onDone()
                    }
                } label: {
                    Text(acceptTitle(proposal, snapshot: snapshot)).frame(maxWidth: .infinity).bold()
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Button("Set my own…") {
                    editText = Format.field(proposal.kcal)
                    showEdit = true
                }
                Button("Skip this week") {
                    if model.skip() {
                        onDone()
                    }
                }
            } footer: {
                Text("A new target applies from today. Past days keep the target they had. Macros keep their current split.")
            }
        }
    }

    private func acceptTitle(_ proposal: TargetProposal, snapshot: ExpenditureSnapshot) -> String {
        if let current = snapshot.currentTarget?.kcal, abs(current - proposal.kcal) < 0.5 {
            return String(localized: "Keep \(model.unit.format(proposal.kcal))")
        }
        return String(localized: "Use \(model.unit.format(proposal.kcal))")
    }
}

/// A number with its label; tapping opens the explanation.
struct FactRow: View {
    let fact: CheckInFact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: NL.Spacing.xs) {
                    Text(fact.value).monospacedDigit().foregroundStyle(.primary)
                    Image(systemName: "info.circle").imageScale(.small).foregroundStyle(.tertiary)
                }
            } label: {
                Text(fact.title).foregroundStyle(.primary)
            }
        }
        .accessibilityHint("Shows how this was computed")
    }
}

struct ExplanationSheet: View {
    let fact: CheckInFact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NL.Spacing.l) {
                    Text(fact.value).font(NL.Typography.largeNumber)
                    Text(fact.explanation)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(fact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "How was this computed": the days of the window with their intake, weigh-in and trend.
struct EstimateDaysView: View {
    let estimate: TDEEEstimate
    let unit: EnergyUnit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(CheckInModel.estimateExplanation(estimate, unit: unit)).font(.footnote)
            }
            Section {
                ForEach(estimate.days.reversed(), id: \.day) { day in
                    VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                        LabeledContent(day.day.startDate().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) {
                            Text(value(day)).monospacedDigit()
                                .foregroundStyle(estimate.isUsed(day) ? .primary : .tertiary)
                        }
                        Text(detail(day)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Days used (\(estimate.loggedDays) of \(estimate.windowDays))")
            } footer: {
                Text("""
                Days with fewer than \(AdaptiveTDEE.minimumEntries) entries are left out unless you mark them as fully \
                logged in the diary, and so are partly logged days: under half of your usual day and not marked \
                as fully logged.
                """)
            }
        }
        .navigationTitle("How it was computed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    /// The day's energy when it went into the mean, else why not.
    private func value(_ day: TDEEDay) -> String {
        if estimate.isPartial(day.day) {
            return String(localized: "\(unit.format(day.kcalIn)) · left out")
        }
        return day.isLogged ? unit.format(day.kcalIn) : String(localized: "not used")
    }

    private func detail(_ day: TDEEDay) -> String {
        var parts: [String] = []
        if estimate.isPartial(day.day) {
            parts.append(String(localized: "partly logged"))
        }
        if day.isComplete {
            parts.append(String(localized: "marked fully logged"))
        } else {
            parts.append(String(localized: "\(day.entryCount) entries"))
        }
        parts.append(day.weightKg.map { String(localized: "weighed \(DashboardFormat.kg($0))") } ?? String(localized: "no weigh-in"))
        if let trend = day.trendKg {
            let kg = "\(trend.formatted(.number.precision(.fractionLength(2)))) kg"
            parts.append(String(localized: "trend \(kg)", comment: "The weight trend of one day, e.g. \"trend 72.35 kg\"."))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - History

/// Past check-ins: estimates and what was decided (backlog #35).
struct CheckInHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var records: [CheckInRecord] = []
    @State private var selected: CheckInRecord?

    var body: some View {
        List {
            if records.isEmpty {
                EmptyStateView(
                    String(localized: "No check-ins yet"), systemImage: "calendar.badge.clock",
                    message: String(localized: "Each weekly check-in is kept here with its estimate and your decision."),
                )
                .listRowBackground(Color.clear)
            }
            ForEach(records) { record in
                Button { selected = record } label: {
                    VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                        LabeledContent(record.computedForDay.startDate().formatted(date: .abbreviated, time: .omitted)) {
                            Text(environment.energyUnit.format(record.tdeeKcal)).monospacedDigit().foregroundStyle(.primary)
                        }
                        .foregroundStyle(.primary)
                        Text(Self.summary(record, unit: environment.energyUnit)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Check-in history")
        .task(id: environment.dataGeneration) {
            guard let repo = environment.checkIns else { return }
            await DiaryModel.resubscribing { repo.observeHistory() } onValue: { records = $0 } onError: { _ in }
        }
        .sheet(item: $selected) { record in
            NavigationStack { CheckInRecordView(record: record, unit: environment.energyUnit) }
        }
    }

    /// "Medium confidence · accepted 2,150 kcal".
    static func summary(_ record: CheckInRecord, unit: EnergyUnit) -> String {
        let decision: String = switch record.decision {
        case .accepted:
            record.appliedTargetKcal.map { String(localized: "accepted \(unit.format($0))") } ?? String(localized: "accepted")
        case .edited:
            record.appliedTargetKcal.map { String(localized: "set own target \(unit.format($0))") } ?? String(localized: "set own target")
        case .skipped: String(localized: "skipped", comment: "Check-in decision: the week's target proposal was skipped.")
        case nil: String(localized: "no decision")
        }
        return "\(record.confidence.title) · \(decision)"
    }
}

/// One past check-in with the same tappable numbers and the days used.
struct CheckInRecordView: View {
    let record: CheckInRecord
    let unit: EnergyUnit
    @Environment(\.dismiss) private var dismiss
    @State private var explaining: CheckInFact?

    var body: some View {
        List {
            Section {
                LabeledContent("Decision", value: CheckInHistoryView.summary(record, unit: unit))
                if let previous = record.previousTargetKcal {
                    LabeledContent("Target before", value: unit.format(previous))
                }
            }
            if let estimate = record.estimate {
                Section("Numbers") {
                    ForEach(facts(estimate)) { fact in
                        FactRow(fact: fact) { explaining = fact }
                    }
                }
                Section {
                    NavigationLink("Days used") { EstimateDaysView(estimate: estimate, unit: unit) }
                }
            } else {
                Section {
                    LabeledContent("Estimated maintenance", value: unit.format(record.tdeeKcal))
                    LabeledContent("Average intake", value: unit.format(record.meanIntakeKcal))
                    LabeledContent("Logged days", value: String(localized: "\(record.loggedDays) of \(record.windowDays)"))
                }
            }
        }
        .navigationTitle(record.computedForDay.startDate().formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(item: $explaining) { ExplanationSheet(fact: $0) }
    }

    /// The stored numbers; the proposal has no note any more, so it gets a plain explanation.
    private func facts(_ estimate: TDEEEstimate) -> [CheckInFact] {
        var facts = CheckInModel.facts(
            estimate: estimate, proposal: nil, goalChangeKgPerWeek: record.goalChangeKgPerWeek ?? 0,
            currentTargetKcal: record.previousTargetKcal, unit: unit,
        )
        if let proposed = record.proposedTargetKcal {
            facts.append(CheckInFact(
                kind: .proposal, title: String(localized: "Proposed target"), value: unit.format(proposed),
                explanation: String(
                    localized: "The target the check-in proposed: estimated maintenance adjusted for your goal at the time.",
                ),
            ))
        }
        return facts
    }
}

// MARK: - Settings

/// Check-in day & reminder (from Trends): the weekday and the opt-in reminder.
struct CheckInSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var weekday = 2
    @State private var reminderOn = false
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Check-in day", selection: $weekday) {
                    ForEach(Self.weekdays, id: \.number) { Text($0.name).tag($0.number) }
                }
            } footer: {
                Text("On this day Vitalion shows your week and proposes a calorie target. You can also open it any time from Trends.")
            }
            Section {
                Toggle("Remind me", isOn: $reminderOn)
            } footer: {
                Text("A notification at \(LocalNotificationCheckInReminder.defaultHour):00 on the check-in day. Off by default.")
            }
            Section {
                NavigationLink("Check-in history") { CheckInHistoryView() }
            }
        }
        .navigationTitle("Weekly check-in")
        .task(id: environment.dataGeneration) { load() }
        .onChange(of: weekday) { save() }
        .onChange(of: reminderOn) { save() }
        .alert("Weekly check-in", isPresented: Binding(get: { message != nil }, set: {
            if !$0 {
                message = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    /// Monday first, numbered as `Calendar.weekday` (1 = Sunday). Names in the user's language.
    static let weekdays: [(number: Int, name: String)] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let names = calendar.standaloneWeekdaySymbols
        return [2, 3, 4, 5, 6, 7, 1].map { ($0, names[$0 - 1]) }
    }()

    private func load() {
        guard let profiles = environment.profiles else { return }
        loaded = false
        weekday = (try? profiles.profile().checkinWeekday) ?? 2
        reminderOn = (try? profiles.setting(SettingKey.checkInReminderEnabled, as: Bool.self)) ?? false
        // Let the onChange handlers of the assignments above run before saving is switched on.
        Task { loaded = true }
    }

    private func save() {
        guard loaded, let profiles = environment.profiles else { return }
        do {
            var profile = try profiles.profile()
            if profile.checkinWeekday != weekday {
                profile.checkinWeekday = weekday
                try profiles.save(profile)
            }
            try profiles.setSetting(SettingKey.checkInReminderEnabled, reminderOn)
        } catch {
            message = String(localized: "Couldn't save: \(error.localizedDescription)")
            return
        }
        let reminder = environment.checkInReminder
        let weekday = weekday, wantsReminder = reminderOn
        Task {
            guard wantsReminder else {
                await reminder.cancel()
                return
            }
            guard await reminder.requestAuthorization() else {
                reminderOn = false
                message = String(
                    localized: "Notifications are turned off for Vitalion. Allow them in the Settings app to get the reminder.",
                )
                return
            }
            do {
                try await reminder.schedule(weekday: weekday, hour: LocalNotificationCheckInReminder.defaultHour)
            } catch {
                message = String(localized: "Couldn't schedule the reminder: \(error.localizedDescription)")
            }
        }
    }
}
