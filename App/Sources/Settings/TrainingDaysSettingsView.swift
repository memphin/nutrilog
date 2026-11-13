import Core
import DesignSystem
import Persistence
import SwiftUI

/// Settings → Training days: the weekdays that are training days, how much a training day raises the calorie
/// target and the hydration goal, and which kinds of Apple Health workouts count as training (a walk doesn't, by
/// default). Saved from today on (`TrainingDayRepository.setSchedule`, `WorkoutRepository.setExcluded`), so past
/// days keep theirs; a single day is switched in the diary, the meal plan or the history calendar.
struct TrainingDaysSettingsView: View {
    /// The boosts offered here (the database allows up to `TrainingSchedule.boostPercentRange`).
    static let boostRange = 0 ... 50
    static let boostStep = 5

    @Environment(AppEnvironment.self) private var environment
    @State private var weekdays: Set<Int> = []
    @State private var boostPercent = TrainingSchedule.defaultBoostPercent
    /// The workout kinds to choose from: those found in Apple Health, and walking.
    @State private var kinds: [WorkoutKind] = []
    /// The kinds that don't count as training.
    @State private var excluded = TrainingRules.defaultExcluded
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.weekdays(calendar: .current), id: \.number) { weekday in
                    Toggle(weekday.name, isOn: Binding(
                        get: { weekdays.contains(weekday.number) },
                        set: { on in
                            var updated = weekdays
                            if on {
                                updated.insert(weekday.number)
                            } else {
                                updated.remove(weekday.number)
                            }
                            save(weekdays: updated, boostPercent: boostPercent)
                        },
                    ))
                }
            } header: {
                Text("Weekdays")
            } footer: {
                Text("Changes apply from today. Past days keep their training status.")
            }

            Section {
                Stepper(
                    value: Binding(get: { boostPercent }, set: { save(weekdays: weekdays, boostPercent: $0) }),
                    in: Self.boostRange,
                    step: Self.boostStep,
                ) {
                    LabeledContent("Goal boost", value: TrainingDayFormat.boost(boostPercent))
                        .monospacedDigit()
                }
            } footer: {
                Text("""
                On a training day your calorie target and hydration goal go up by this much. The extra calories are \
                added as carbs.
                """)
            }

            Section {
                ForEach(kinds) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { !excluded.contains(kind) },
                        set: { on in
                            var updated = excluded
                            if on {
                                updated.remove(kind)
                            } else {
                                updated.insert(kind)
                            }
                            save(excluded: updated)
                        },
                    ))
                }
            } header: {
                Text("Counts as training")
            } footer: {
                Text("""
                A workout from Apple Health that counts as training is a session on the Training tab and makes its day a \
                training day. The others are listed as activity only. Changes apply from today.
                """)
            }
        }
        .navigationTitle("Training days")
        .task(id: Key(generation: environment.dataGeneration, synced: environment.healthSync?.lastSyncedAt)) { load() }
        .errorAlert($errorMessage)
    }

    /// The seven weekdays, numbered as `Calendar.weekday` (1 = Sunday), from `calendar`'s first weekday on, with
    /// their standalone names in `calendar`'s locale.
    static func weekdays(calendar: Calendar) -> [(number: Int, name: String)] {
        let names = calendar.standaloneWeekdaySymbols
        return (0 ..< 7).map { offset in
            let number = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (number, names[number - 1])
        }
    }

    /// Reloaded after an import and after a Health sync (a new kind of workout may have arrived).
    private struct Key: Hashable {
        var generation: Int
        var synced: Date?
    }

    /// The kinds to list: every kind Apple Health has a workout of, plus walking and whatever is switched off, by name.
    static func kinds(found: [WorkoutKind], excluded: Set<WorkoutKind>) -> [WorkoutKind] {
        Set(found).union(excluded).union([.walking])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Today's schedule, or no training days at the default boost; and the kinds that count as training now.
    private func load() {
        let schedule = try? environment.trainingDays?.schedule(on: environment.today)
        weekdays = schedule?.weekdays ?? []
        boostPercent = schedule?.boostPercent ?? TrainingSchedule.defaultBoostPercent
        excluded = (try? environment.workouts?.rules())?.currentExcluded ?? TrainingRules.defaultExcluded
        kinds = Self.kinds(found: (try? environment.workouts?.kinds()) ?? [], excluded: excluded)
    }

    /// Saves which kinds count as training from today on; shows it only once saved.
    private func save(excluded updated: Set<WorkoutKind>) {
        guard let repo = environment.workouts, updated != excluded else { return }
        do {
            try repo.setExcluded(updated, from: environment.today)
            excluded = updated
        } catch {
            errorMessage = String(localized: "Couldn't save the training days: \(error.localizedDescription)")
        }
    }

    /// Saves the schedule from today on (replacing one already saved today); shows it only once saved.
    private func save(weekdays: Set<Int>, boostPercent: Int) {
        guard let repo = environment.trainingDays,
              weekdays != self.weekdays || boostPercent != self.boostPercent else { return }
        do {
            try repo.setSchedule(weekdays: weekdays, boostPercent: boostPercent, effectiveFrom: environment.today)
            self.weekdays = weekdays
            self.boostPercent = boostPercent
        } catch {
            errorMessage = String(localized: "Couldn't save the training days: \(error.localizedDescription)")
        }
    }
}
