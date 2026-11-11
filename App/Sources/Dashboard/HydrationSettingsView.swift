import Core
import DesignSystem
import Persistence
import SwiftUI
import UIKit

/// Settings → Hydration: the daily goal (from weight or a fixed amount), the water quick-add sizes (FR-46), the waking
/// window the pace runs in, and reminders.
struct HydrationSettingsView: View {
    static let fixedGoalRange = 500.0 ... 6000
    static let fixedGoalStep = 250.0

    @Environment(AppEnvironment.self) private var environment
    @State private var settings = HydrationSettings.default
    @State private var goalMode: HydrationGoalMode = .weight
    @State private var fixedGoalMl = HydrationGoal.fallbackMl
    @State private var trendKg: Double?
    @State private var quickAddRows = WaterQuickAdd.defaultSizes.map { WaterQuickAddRow(ml: $0) }
    @State private var notificationsDenied = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            goalSection
            WaterQuickAddSizesSection(rows: $quickAddRows, errorMessage: $errorMessage)
            daySection
            remindersSection
        }
        .navigationTitle("Hydration")
        .task(id: environment.dataGeneration) { load() }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Sections

    private var goalSection: some View {
        Section("Goal") {
            Picker("Daily goal", selection: Binding(get: { goalMode }, set: { saveGoal(mode: $0, fixedMl: fixedGoalMl) })) {
                Text("Based on weight (\(Self.number(HydrationGoal.mlPerKg)) ml/kg)").tag(HydrationGoalMode.weight)
                Text("Fixed amount").tag(HydrationGoalMode.fixed)
            }
            switch goalMode {
            case .weight:
                if let trendKg {
                    let goal = HydrationGoalResolver.goalMl(on: environment.today, mode: .weight, fixedMl: fixedGoalMl, trendKg: trendKg)
                    Text("\(Self.number(goal)) ml at \(trendKg.formatted(.number.precision(.fractionLength(1)))) kg")
                        .monospacedDigit()
                } else {
                    Text("Log your weight to personalise this goal").foregroundStyle(.secondary)
                }
            case .fixed:
                Stepper(
                    value: Binding(get: { fixedGoalMl }, set: { saveGoal(mode: goalMode, fixedMl: $0) }),
                    in: Self.fixedGoalRange,
                    step: Self.fixedGoalStep,
                ) {
                    LabeledContent("Goal", value: "\(Self.number(fixedGoalMl)) ml")
                }
            }
        }
    }

    private var daySection: some View {
        Section {
            DatePicker("Wake-up time", selection: time(\.fallbackWakeMinutes), displayedComponents: .hourAndMinute)
            DatePicker("Bedtime", selection: time(\.bedtimeMinutes), displayedComponents: .hourAndMinute)
        } header: {
            Text("Your day")
        } footer: {
            Text("Uses the time you woke up from Apple Health sleep when available.")
        }
    }

    private var remindersSection: some View {
        Section("Reminders") {
            Toggle("Remind me to drink", isOn: Binding(get: { settings.remindersEnabled }, set: setReminders))
            if notificationsDenied {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    Text("Notifications are off for Vitalion")
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Link("Open Settings", destination: url)
                    }
                }
            }
            Stepper(
                value: binding(\.gapMinutes),
                in: HydrationSettings.gapRange,
                step: HydrationSettings.gapStep,
            ) {
                Text("Remind after \(Self.hours(settings.gapMinutes)) without a drink")
            }
            Stepper(
                value: binding(\.behindMarginMl),
                in: HydrationSettings.marginRange,
                step: HydrationSettings.marginStep,
            ) {
                Text("Or when \(Self.number(settings.behindMarginMl)) ml behind pace")
            }
        }
    }

    // MARK: Formatting

    /// "2,400" (whole number, grouped for the locale).
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// "3 h", "1.5 h".
    static func hours(_ minutes: Int) -> String {
        "\((Double(minutes) / 60).formatted(.number.precision(.fractionLength(0 ... 1)))) h"
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<HydrationSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    /// A minutes-from-midnight setting as a time of today, for a `DatePicker`.
    private func time(_ keyPath: WritableKeyPath<HydrationSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                update { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            },
        )
    }

    // MARK: Loading and saving

    private func load() {
        guard let profiles = environment.profiles else { return }
        settings = HydrationSettings.load(from: profiles)
        quickAddRows = WaterQuickAddSizesSection.rows(for: WaterQuickAdd.sizes(from: profiles), reusing: quickAddRows)
        if let profile = try? profiles.profile() {
            goalMode = profile.waterGoalMode
            fixedGoalMl = profile.waterGoalMl
        }
        let today = environment.today
        trendKg = HydrationGoalResolver.trendsKg(in: today ... today, from: environment.dailyMetrics)[today]
    }

    private func saveGoal(mode: HydrationGoalMode, fixedMl: Double) {
        guard let profiles = environment.profiles else { return }
        do {
            var profile = try profiles.profile()
            guard profile.waterGoalMode != mode || profile.waterGoalMl != fixedMl else { return }
            profile.waterGoalMode = mode
            profile.waterGoalMl = fixedMl
            try profiles.save(profile)
            goalMode = mode
            fixedGoalMl = fixedMl
            environment.widgetDataDidChange() // the water widget shows the goal
        } catch {
            errorMessage = "Couldn't save the hydration goal: \(error.localizedDescription)"
        }
    }

    /// On: asks for notification permission and turns back off when it is denied. Scheduling follows the setting.
    private func setReminders(_ on: Bool) {
        update { $0.remindersEnabled = on }
        guard on else {
            notificationsDenied = false
            return
        }
        let reminder = environment.hydrationReminder
        Task {
            if await reminder.requestAuthorization() {
                notificationsDenied = false
                environment.refreshHydrationReminder() // saved before permission was given: plan it now
            } else {
                update { $0.remindersEnabled = false }
                notificationsDenied = true
            }
        }
    }

    /// Applies `change` and saves; the screen shows what was saved.
    private func update(_ change: (inout HydrationSettings) -> Void) {
        guard let profiles = environment.profiles else { return }
        var updated = settings
        change(&updated)
        do {
            settings = try updated.save(to: profiles)
            environment.refreshHydrationReminder()
        } catch {
            errorMessage = "Couldn't save the hydration settings: \(error.localizedDescription)"
        }
    }
}

// MARK: - Quick-add sizes

/// The water quick-add sizes (FR-46): up to four button sizes in ml, as sections of `HydrationSettingsView`.
/// One quick-add size on screen. The id stays with the row while its value changes (and the rows re-sort), so a held
/// stepper keeps acting on the same row and a deleted row is the one that animates away.
private struct WaterQuickAddRow: Identifiable, Equatable {
    let id = UUID()
    var ml: Int
}

private struct WaterQuickAddSizesSection: View {
    typealias SizeRow = WaterQuickAddRow

    @Environment(AppEnvironment.self) private var environment
    /// Loaded by `HydrationSettingsView` with the rest of the screen, so they're current before any row appears.
    @Binding var rows: [SizeRow]
    @Binding var errorMessage: String?

    var body: some View {
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                // nil disables "+" / "−" when no free step is left that way (as `in:` did at the range ends).
                Stepper(
                    label: { LabeledContent("Button \(position + 1)", value: "\(row.ml) ml") },
                    onIncrement: canStep(row, by: 50) ? { step(row.id, by: 50) } : nil,
                    onDecrement: canStep(row, by: -50) ? { step(row.id, by: -50) } : nil,
                )
                .deleteDisabled(rows.count <= 1)
            }
            .onDelete { offsets in
                // The last size can't be swiped away (`deleteDisabled`); this guard only backs that up.
                guard rows.count > offsets.count else { return }
                var updated = rows
                updated.remove(atOffsets: offsets)
                save(updated)
            }
            if rows.count < WaterQuickAdd.maximumCount {
                Button("Add size", systemImage: "plus") {
                    if let next = WaterQuickAdd.nextSize(after: rows.map(\.ml)) {
                        save(rows + [SizeRow(ml: next)])
                    }
                }
                .disabled(WaterQuickAdd.nextSize(after: rows.map(\.ml)) == nil)
            }
        } header: {
            Text("Quick-add sizes")
        } footer: {
            Text("The water buttons on the Today screen, smallest first. Stepping onto another size skips past it.")
        }
        Section {
            Button("Reset to 250 and 500 ml") { save(Self.rows(for: WaterQuickAdd.defaultSizes, reusing: rows)) }
        }
    }

    private func canStep(_ row: SizeRow, by delta: Int) -> Bool {
        let others = rows.filter { $0.id != row.id }.map(\.ml)
        return WaterQuickAdd.stepped(row.ml, by: delta, among: others) != row.ml
    }

    /// A stepper tap (or autorepeat tick) on the row `id`. Looks the row up by id at call time, so a tick after the
    /// rows changed never reads a stale index; does nothing when the row is gone or no free step is left.
    private func step(_ id: SizeRow.ID, by delta: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let others = rows.filter { $0.id != id }.map(\.ml)
        let value = WaterQuickAdd.stepped(rows[index].ml, by: delta, among: others)
        guard value != rows[index].ml else { return }
        var updated = rows
        updated[index].ml = value
        save(updated)
    }

    /// Saves the sizes (sorted, unique, 1–4) and shows what was saved, keeping each row's identity.
    private func save(_ updated: [SizeRow]) {
        if let normalized = persist(updated.map(\.ml)) {
            rows = Self.rows(for: normalized, reusing: updated)
        }
    }

    /// `sizes` as rows in their order, reusing the id of an existing row with the same value where there is one.
    static func rows(for sizes: [Int], reusing existing: [SizeRow]) -> [SizeRow] {
        var remaining = existing
        return sizes.map { ml in
            if let index = remaining.firstIndex(where: { $0.ml == ml }) {
                return remaining.remove(at: index)
            }
            return SizeRow(ml: ml)
        }
    }

    @discardableResult
    private func persist(_ updated: [Int]) -> [Int]? {
        guard let profiles = environment.profiles else { return nil }
        do {
            let saved = try WaterQuickAdd.save(updated, to: profiles)
            environment.refreshHydrationReminder() // the reminder's action adds the smallest size
            return saved
        } catch {
            errorMessage = "Couldn't save the sizes: \(error.localizedDescription)"
            return nil
        }
    }
}

#Preview {
    NavigationStack { HydrationSettingsView() }.environment(AppEnvironment.preview())
}
