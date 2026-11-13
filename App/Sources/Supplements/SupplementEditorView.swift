import Core
import DesignSystem
import Persistence
import SwiftUI

/// Adds or edits a supplement or medication: name, dose, note, schedule (times and weekdays, or as needed) and
/// reminders.
struct SupplementEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let supplement: Supplement?

    @State private var name = ""
    @State private var dose = ""
    @State private var note = ""
    @State private var asNeeded = false
    @State private var times: [Date] = []
    @State private var everyDay = true
    @State private var weekdays: Set<Int> = []
    @State private var remindersEnabled = true
    @State private var isActive = true
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(supplement: Supplement?) {
        self.supplement = supplement
        guard let supplement else {
            _times = State(initialValue: [SupplementFormat.date(8 * 60)])
            return
        }
        let schedule = supplement.schedule
        _name = State(initialValue: supplement.name)
        _dose = State(initialValue: supplement.dose)
        _note = State(initialValue: supplement.note ?? "")
        _asNeeded = State(initialValue: schedule.isAsNeeded)
        let times = schedule.isAsNeeded ? [8 * 60] : schedule.times
        _times = State(initialValue: times.map { SupplementFormat.date($0) })
        _everyDay = State(initialValue: schedule.isEveryDay)
        _weekdays = State(initialValue: schedule.isEveryDay ? [] : schedule.weekdays)
        _remindersEnabled = State(initialValue: supplement.remindersEnabled)
        _isActive = State(initialValue: supplement.isActive)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (asNeeded || (!times.isEmpty && (everyDay || !weekdays.isEmpty)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Vitamin D3", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Dose, e.g. 1 tablet or 500 mg", text: $dose)
                    TextField("Note, e.g. with food", text: $note)
                }

                Section {
                    Picker("When", selection: $asNeeded) {
                        Text("At set times").tag(false)
                        Text("As needed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !asNeeded {
                        ForEach(times.indices, id: \.self) { index in
                            DatePicker("Dose \(index + 1)", selection: $times[index], displayedComponents: .hourAndMinute)
                        }
                        .onDelete { times.remove(atOffsets: $0) }
                        Button("Add a time", systemImage: "plus") {
                            let last = times.last.map { SupplementFormat.minute(of: $0) } ?? 8 * 60
                            times.append(SupplementFormat.date(min(last + 4 * 60, 23 * 60)))
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if asNeeded {
                        Text("Log a dose from the diary whenever you take one. No reminders.")
                    }
                }

                if !asNeeded {
                    Section {
                        Toggle("Every day", isOn: $everyDay)
                        if !everyDay {
                            WeekdayPicker(selection: $weekdays)
                        }
                    }

                    Section {
                        Toggle("Remind me", isOn: $remindersEnabled)
                    } footer: {
                        Text("At each time, and once more an hour later if not taken.")
                    }
                }

                if supplement != nil {
                    Section {
                        Toggle("Taking it now", isOn: $isActive)
                    } footer: {
                        Text("Switch off what you stopped taking: it leaves the diary and the reminders, and the doses you logged stay.")
                    }
                    Section {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(supplement == nil ? "New supplement" : "Edit supplement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(trimmedName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("Its logged doses are no longer shown. To keep them, switch it off instead.")
            }
            .errorAlert($errorMessage, title: "Supplements")
        }
    }

    private func save() {
        guard let repo = environment.supplements else { return }
        let schedule = asNeeded
            ? SupplementSchedule.asNeeded
            : SupplementSchedule(times: times.map { SupplementFormat.minute(of: $0) }, weekdays: everyDay ? [] : weekdays)
        var record = supplement ?? Supplement(name: trimmedName, schedule: schedule, startDay: environment.today)
        record.name = name
        record.dose = dose
        record.note = note
        record.schedule = schedule
        record.remindersEnabled = remindersEnabled
        record.isActive = isActive
        do {
            try repo.save(record)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let wantsReminders = isActive && remindersEnabled && !asNeeded && environment.supplementRemindersEnabled
        Task {
            if wantsReminders {
                _ = await environment.supplementReminder.requestAuthorization() // asks only the first time
            }
            environment.refreshSupplementReminders()
        }
        dismiss()
    }

    private func delete() {
        guard let supplement, let repo = environment.supplements else { return }
        do {
            try repo.delete(id: supplement.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Seven round buttons, one per weekday, starting at the calendar's first weekday.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        HStack {
            ForEach(SupplementFormat.weekdayOrder(calendar), id: \.self) { weekday in
                let isOn = selection.contains(weekday)
                Button {
                    if isOn {
                        selection.remove(weekday)
                    } else {
                        selection.insert(weekday)
                    }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
