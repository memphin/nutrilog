import Core
import DesignSystem
import Persistence
import SwiftUI

/// Settings → Training days: the weekdays that are training days and how much a training day raises the calorie
/// target and the hydration goal. Saved as a schedule from today on (`TrainingDayRepository.setSchedule`), so past
/// days keep theirs; a single day is switched in the diary, the meal plan or the history calendar.
struct TrainingDaysSettingsView: View {
    /// The boosts offered here (the database allows up to `TrainingSchedule.boostPercentRange`).
    static let boostRange = 0 ... 50
    static let boostStep = 5

    @Environment(AppEnvironment.self) private var environment
    @State private var weekdays: Set<Int> = []
    @State private var boostPercent = TrainingSchedule.defaultBoostPercent
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
        }
        .navigationTitle("Training days")
        .task(id: environment.dataGeneration) { load() }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
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

    /// Today's schedule, or no training days at the default boost.
    private func load() {
        let schedule = try? environment.trainingDays?.schedule(on: environment.today)
        weekdays = schedule?.weekdays ?? []
        boostPercent = schedule?.boostPercent ?? TrainingSchedule.defaultBoostPercent
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
