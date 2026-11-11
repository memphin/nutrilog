import Core
import DesignSystem
import Persistence
import SwiftUI

/// Picks a day with a graphical calendar.
struct DayPickerSheet: View {
    @Binding var day: LocalDay
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Go to day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            day = LocalDay(date)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { date = day.startDate() }
    }
}

/// "Copy from date…" — choose the source day.
struct CopyFromDateSheet: View {
    let defaultDay: LocalDay
    let title: String
    let onCopy: (LocalDay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Copy from", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy") {
                            onCopy(LocalDay(date))
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { date = defaultDay.startDate() }
    }
}

/// Moves an entry (logged or planned) to another day and slot.
struct MoveToDateSheet: View {
    let title: String
    let initialDay: LocalDay
    let initialSlotID: String
    let slots: [MealSlot]
    /// A logged (eaten) entry can't move to a future day: there it would count as eaten ahead of time. Plans can.
    let allowsFuture: Bool
    let onMove: (String, LocalDay) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var slotID = ""

    init(
        title: String, day: LocalDay, slotID: String, slots: [MealSlot], allowsFuture: Bool = true,
        onMove: @escaping (String, LocalDay) -> Void,
    ) {
        self.title = title
        initialDay = day
        initialSlotID = slotID
        self.slots = slots
        self.allowsFuture = allowsFuture
        self.onMove = onMove
    }

    /// A logged entry: today or earlier only.
    init(entry: DiaryEntry, slots: [MealSlot], onMove: @escaping (String, LocalDay) -> Void) {
        self.init(
            title: "Move \(entry.displayName)", day: entry.day, slotID: entry.mealSlotID, slots: slots, allowsFuture: false,
            onMove: onMove,
        )
    }

    /// The latest day the picker offers; nil when any day is fine.
    private var latestDay: LocalDay? {
        allowsFuture ? nil : environment.today
    }

    /// The picker's range: up to the last moment of `latestDay`.
    private var dateRange: ClosedRange<Date> {
        let upper = latestDay.map { $0.next.startDate().addingTimeInterval(-1) } ?? .distantFuture
        return Date.distantPast ... upper
    }

    /// The chosen day, never after `latestDay` (the picker's range already keeps it there).
    private var chosenDay: LocalDay {
        let day = LocalDay(date)
        guard let latestDay else { return day }
        return min(day, latestDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $date, in: dateRange, displayedComponents: .date)
                Picker("Meal", selection: $slotID) {
                    ForEach(slots) { Text($0.name).tag($0.id) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onMove(slotID, chosenDay)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            date = initialDay.startDate()
            slotID = initialSlotID
        }
    }
}

/// Free-text day note + "fully logged" toggle (FR-7).
struct DayNoteEditor: View {
    let note: DayNote?
    let onSave: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isComplete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. cheat day, sick, travelling", text: $text, axis: .vertical)
                        .lineLimit(3 ... 8)
                }
                Section {
                    Toggle("Day fully logged", isOn: $isComplete)
                } footer: {
                    Text("Fully logged days are trusted by the adaptive TDEE estimate even with few entries.")
                }
            }
            .navigationTitle("Day note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), isComplete)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            text = note?.text ?? ""
            isComplete = note?.isComplete ?? false
        }
    }
}

/// Tapping an entry: quantity sheet for food entries, quick-add form for quick-adds.
struct EditEntryView: View {
    let entry: DiaryEntry
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if entry.isQuickAdd {
            QuickAddView(mode: .edit(entry))
        } else {
            NavigationStack {
                QuantitySheet(detail: detailForEntry, mode: .edit(entry)) { dismiss() }
            }
        }
    }

    /// The food if it still exists; otherwise a stand-in built from the entry's snapshot so the amount
    /// can still be changed.
    private var detailForEntry: FoodDetail {
        if let id = entry.foodID, let detail = try? environment.foods?.detail(id: id) {
            return detail
        }
        let per100 = entry.grams > 0 ? entry.nutrients.scaled(by: 100 / entry.grams) : entry.nutrients
        return FoodDetail(food: Food(id: entry.foodID ?? entry.id, name: entry.displayName, per100: per100))
    }
}
