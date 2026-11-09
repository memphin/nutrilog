import Core
import Foundation
import Observation
import Persistence

/// State and actions for the diary day view (backlog #7, #10, #12).
@MainActor
@Observable
final class DiaryModel {
    var day: LocalDay
    private(set) var diary: DayDiary?
    private(set) var target: Target?
    /// Foods in the current day measured in ml (entries only store the amount).
    private(set) var liquidFoodIDs: Set<String> = []
    var errorMessage: String?
    let undo = UndoCenter()

    private let environment: AppEnvironment

    init(environment: AppEnvironment, day: LocalDay? = nil) {
        self.environment = environment
        self.day = day ?? environment.today
    }

    var today: LocalDay {
        environment.today
    }

    var isToday: Bool {
        day == today
    }

    var energyUnit: EnergyUnit {
        environment.energyUnit
    }

    var slots: [MealSlot] {
        diary?.sections.map(\.slot).filter(\.isActive) ?? []
    }

    // MARK: Observation

    /// Streams the diary of `day`; restarted by the view whenever `day` changes.
    func observeDiary() async {
        guard let repo = environment.diary else { return }
        do {
            for try await value in repo.observeDiary(for: day) {
                diary = value
                let ids = Set(value.sections.flatMap(\.entries).compactMap(\.foodID))
                liquidFoodIDs = Set(ids.filter { (try? environment.foods?.food(id: $0))??.isLiquid == true })
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func observeTarget() async {
        guard let repo = environment.profiles else { return }
        do {
            for try await value in repo.observeTarget(on: day) {
                target = value
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Navigation

    func goToPreviousDay() {
        day = day.previous
    }

    func goToNextDay() {
        day = day.next
    }

    func goToToday() {
        day = today
    }

    // MARK: Entry actions

    func delete(_ entries: [DiaryEntry]) {
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return }
        perform { try $0.softDelete(entryIDs: ids) }
        let message = entries.count == 1 ? "Deleted \(entries[0].displayName)" : "Deleted \(entries.count) entries"
        undo.offer(message) { [weak self] in
            self?.perform { try $0.restore(entryIDs: ids) }
        }
    }

    func duplicate(_ entry: DiaryEntry) {
        perform { _ = try $0.duplicate(entryID: entry.id) }
    }

    func move(_ entry: DiaryEntry, toSlot slotID: String, day targetDay: LocalDay? = nil) {
        perform { try $0.move(entryID: entry.id, toSlot: slotID, day: targetDay ?? entry.day) }
    }

    func reorder(in section: DayDiary.Section, from source: IndexSet, to destination: Int) {
        var ids = section.entries.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        perform { try $0.reorder(day: day, slotID: section.slot.id, orderedIDs: ids) }
    }

    // MARK: Copy (backlog #12)

    /// Copies one meal (or the whole day when `slotID` is nil) from `source` into the current day.
    func copy(from source: LocalDay, slotID: String?) {
        guard let repo = environment.diary else { return }
        do {
            let ids = try repo.copy(from: source, slotID: slotID, to: day)
            guard !ids.isEmpty else {
                errorMessage = "Nothing to copy — \(Format.day(source, today: today)) has no entries\(slotID == nil ? "" : " in that meal")."
                return
            }
            undo.offer("Copied \(ids.count) \(ids.count == 1 ? "entry" : "entries")") { [weak self] in
                self?.perform { try $0.softDelete(entryIDs: ids) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Day note

    func saveNote(text: String, isComplete: Bool) {
        perform { try $0.setDayNote(day: day, text: text, isComplete: isComplete) }
    }

    func toggleComplete() {
        let note = diary?.note
        saveNote(text: note?.text ?? "", isComplete: !(note?.isComplete ?? false))
    }

    // MARK: Helpers

    private func perform(_ action: (DiaryRepository) throws -> Void) {
        guard let repo = environment.diary else { return }
        do {
            try action(repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
