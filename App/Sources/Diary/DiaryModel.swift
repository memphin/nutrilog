import Core
import Foundation
import Observation
import Persistence

/// State and actions for the diary day view (backlog #7, #10, #12).
@MainActor
@Observable
final class DiaryModel {
    /// The day shown. While it is today it follows `AppEnvironment.today`, so after midnight (or a night in
    /// the background) the diary moves on to the new day instead of logging to yesterday.
    var day: LocalDay {
        get { followsToday ? environment.today : pinnedDay }
        set {
            pinnedDay = newValue
            followsToday = newValue == environment.today
        }
    }

    private(set) var diary: DayDiary?
    private(set) var target: Target?
    /// Foods in the current day measured in ml (entries only store the amount).
    private(set) var liquidFoodIDs: Set<String> = []
    var errorMessage: String?
    let undo = UndoCenter()
    /// The adaptive maintenance estimate, for the under-logging hint (backlog #36); nil until there is one.
    private(set) var estimateKcal: Double?

    private let environment: AppEnvironment
    private var pinnedDay: LocalDay
    private var followsToday: Bool

    init(environment: AppEnvironment, day: LocalDay? = nil) {
        self.environment = environment
        let start = day ?? environment.today
        pinnedDay = start
        followsToday = start == environment.today
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

    /// Slots an entry can be moved to: the active ones plus the entry's own slot, even when inactive.
    func moveTargets(for entry: DiaryEntry) -> [MealSlot] {
        var result = slots
        if !result.contains(where: { $0.id == entry.mealSlotID }),
           let own = diary?.sections.first(where: { $0.slot.id == entry.mealSlotID })?.slot
           ?? (try? environment.diary?.mealSlots(includeInactive: true))?.first(where: { $0.id == entry.mealSlotID })
        {
            result.append(own)
            result.sort { $0.sortOrder < $1.sortOrder }
        }
        return result
    }

    // MARK: Observation

    /// Streams the diary of `day`; restarted by the view whenever `day` changes, and resubscribed after an error.
    func observeDiary() async {
        guard let repo = environment.diary else { return }
        let day = day
        await Self.resubscribing {
            repo.observeDiary(for: day)
        } onValue: { value in
            diary = value
            let ids = Set(value.sections.flatMap(\.entries).compactMap(\.foodID))
            liquidFoodIDs = Set(ids.filter { (try? environment.foods?.food(id: $0))??.isLiquid == true })
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    func observeTarget() async {
        guard let repo = environment.profiles else { return }
        let day = day
        await Self.resubscribing {
            repo.observeTarget(on: day)
        } onValue: { value in
            target = value
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    /// Iterates `makeSequence()` until the task is cancelled. After an error the sequence is started again
    /// with a growing delay (up to 30 s), so a transient database error doesn't freeze the screen; the error
    /// is reported once per run of failures.
    static func resubscribing<S: AsyncSequence>(
        retryDelay: Duration = .seconds(1),
        _ makeSequence: () -> S,
        onValue: (S.Element) -> Void,
        onError: (any Error) -> Void,
    ) async {
        var delay = retryDelay
        var reported = false
        while !Task.isCancelled {
            do {
                for try await value in makeSequence() {
                    reported = false
                    delay = retryDelay
                    onValue(value)
                }
                return // ended: the task was cancelled (observations never finish on their own)
            } catch {
                if Task.isCancelled {
                    return
                }
                if !reported {
                    reported = true
                    onError(error)
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
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
        guard !ids.isEmpty, perform({ try $0.softDelete(entryIDs: ids) }) else { return }
        let message = entries.count == 1 ? "Deleted \(entries[0].displayName)" : "Deleted \(entries.count) entries"
        offerUndo(message) { try $0.restore(entryIDs: ids) }
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
            offerUndo("Copied \(ids.count) \(ids.count == 1 ? "entry" : "entries")") { try $0.softDelete(entryIDs: ids) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Saved meals (backlog #32)

    /// "Save as meal": a saved meal from the food entries of one slot of the current day.
    @discardableResult
    func saveAsMeal(slotID: String, name: String) -> Bool {
        guard let meals = environment.meals else { return false }
        do {
            let meal = try meals.createFromDiary(day: day, slotID: slotID, name: name)
            undo.offer("Saved meal “\(meal.template.name)”") { [weak self] in
                do {
                    try meals.softDelete(id: meal.id)
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
            return true
        } catch let PersistenceError.validation(message) {
            errorMessage = message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Fully logged days and under-logging (backlog #36)

    /// Re-reads the maintenance estimate the hint compares a day with.
    func reloadEstimate() {
        estimateKcal = (try? Expenditure.snapshot(environment: environment))?.kcal
    }

    /// A gentle hint for a finished day that looks incompletely logged; nil otherwise. Never changes any target.
    var loggingHint: String? {
        guard let diary else { return nil }
        return DiaryHints.hint(
            day: day, today: today, kcal: diary.totals.kcal, entryCount: diary.entryCount,
            isComplete: diary.note?.isComplete ?? false, estimateKcal: estimateKcal, unit: energyUnit,
        )
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

    /// Offers `action` as undo. It is skipped when the data was replaced since (JSON import), and the toast
    /// is cleared by the view at that point.
    private func offerUndo(_ message: String, _ action: @escaping (DiaryRepository) throws -> Void) {
        let generation = environment.dataGeneration
        undo.offer(message) { [weak self] in
            guard let self, environment.dataGeneration == generation else { return }
            perform(action)
        }
    }

    /// Clears a pending undo when the data changed underneath it.
    func dataDidChangeExternally() {
        undo.dismiss()
    }

    @discardableResult
    private func perform(_ action: (DiaryRepository) throws -> Void) -> Bool {
        guard let repo = environment.diary else { return false }
        do {
            try action(repo)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Hints about days that look incompletely logged (SPEC §5.4.1 inputs, backlog #36). Informational only: the app
/// warns, it never lowers a target because of a low day.
enum DiaryHints {
    static func hint(
        day: LocalDay, today: LocalDay, kcal: Double, entryCount: Int, isComplete: Bool, estimateKcal: Double?, unit: EnergyUnit,
    ) -> String? {
        // Today is still being logged; a day marked complete is trusted as it is; an empty day says nothing.
        guard day < today, !isComplete, entryCount > 0 else { return nil }
        if AdaptiveTDEE.looksUnderLogged(dayKcal: kcal, isComplete: isComplete, estimateKcal: estimateKcal), let estimateKcal {
            return "\(unit.format(kcal)) is less than half of your estimated \(unit.format(estimateKcal)) a day. "
                + "If something is missing, add it. If this really was everything, mark the day as fully logged."
        }
        if entryCount < AdaptiveTDEE.minimumEntries {
            return "Days with fewer than \(AdaptiveTDEE.minimumEntries) entries are left out of the maintenance estimate. "
                + "Mark the day as fully logged if this was everything you ate."
        }
        return nil
    }
}
