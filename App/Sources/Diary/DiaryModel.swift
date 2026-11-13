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
    /// The day's meal plan that is not eaten yet.
    private(set) var planned: [PlannedEntry] = []
    /// The target in effect on the day, before a training day's boost (`target`).
    private(set) var baseTarget: Target?
    /// The day's training status and boost (schedule and the day's override).
    private(set) var training: TrainingDays = .none
    /// Foods in the current day (entries and plan) measured in ml (entries only store the amount).
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

    /// A day after today: new food goes to the meal plan, and plans can't be confirmed as eaten yet.
    var isFuture: Bool {
        day > today
    }

    var energyUnit: EnergyUnit {
        environment.energyUnit
    }

    var slots: [MealSlot] {
        diary?.sections.map(\.slot).filter(\.isActive) ?? []
    }

    /// A meal of the day view: its logged entries, and the planned ones (`planned(in:)`) shown below them.
    struct MealSection: Identifiable, Hashable {
        let slot: MealSlot
        let entries: [DiaryEntry]
        var id: String {
            slot.id
        }

        var totals: Nutrients {
            Nutrients.sum(entries.map(\.nutrients))
        }
    }

    /// The diary's sections plus one for every switched-off slot that still holds planned food, in slot order: the
    /// diary keeps an inactive slot only while it has entries, but its plan still counts and must stay editable.
    var sections: [MealSection] {
        guard let diary else { return [] }
        var result = diary.sections.map { MealSection(slot: $0.slot, entries: $0.entries) }
        let shown = Set(result.map(\.id))
        let missing = Set(planned.map(\.mealSlotID)).subtracting(shown)
        guard !missing.isEmpty else { return result }
        let all = (try? environment.diary?.mealSlots(includeInactive: true)) ?? []
        result += all.filter { missing.contains($0.id) }.map { MealSection(slot: $0, entries: []) }
        result.sort { $0.slot.sortOrder < $1.slot.sortOrder }
        return result
    }

    /// Slots an entry can be moved to: the active ones plus the entry's own slot, even when inactive.
    func moveTargets(for entry: DiaryEntry) -> [MealSlot] {
        moveTargets(ownSlotID: entry.mealSlotID)
    }

    /// Slots a planned entry can be moved to: the active ones plus its own slot, even when inactive.
    func moveTargets(for entry: PlannedEntry) -> [MealSlot] {
        moveTargets(ownSlotID: entry.mealSlotID)
    }

    private func moveTargets(ownSlotID: String) -> [MealSlot] {
        var result = slots
        if !result.contains(where: { $0.id == ownSlotID }),
           let own = diary?.sections.first(where: { $0.slot.id == ownSlotID })?.slot
           ?? (try? environment.diary?.mealSlots(includeInactive: true))?.first(where: { $0.id == ownSlotID })
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
            refreshLiquidFoods()
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    func observePlan() async {
        guard let repo = environment.mealPlan else { return }
        let day = day
        await Self.resubscribing {
            repo.observePending(in: day ... day)
        } onValue: { value in
            planned = value
            refreshLiquidFoods()
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    /// Which foods of the day's entries and plan are measured in ml.
    private func refreshLiquidFoods() {
        let ids = Set((diary?.sections.flatMap(\.entries).compactMap(\.foodID) ?? []) + planned.compactMap(\.foodID))
        liquidFoodIDs = Set(ids.filter { (try? environment.foods?.food(id: $0))??.isLiquid == true })
    }

    func observeTarget() async {
        guard let repo = environment.profiles else { return }
        let day = day
        await Self.resubscribing {
            repo.observeTarget(on: day)
        } onValue: { value in
            baseTarget = value
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    /// Streams whether the day is a training day (Settings → Training days, the day's switch here or elsewhere).
    func observeTraining() async {
        guard let repo = environment.trainingDays else { return }
        let day = day
        await Self.resubscribing {
            repo.observeTrainingDays(in: day ... day)
        } onValue: { value in
            if training != value {
                training = value
            }
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Training day

    /// The day's calorie and macro target: `baseTarget`, boosted on a training day.
    var target: Target? {
        training.effectiveTarget(baseTarget, on: day)
    }

    var isTrainingDay: Bool {
        training.isTraining(day)
    }

    /// The boost a training day gets on this day (whether or not it is one), in percent.
    var trainingBoostPercent: Int {
        training.boostPercent(on: day)
    }

    /// The day's training switch: makes it a training day or a rest day (`TrainingDayRepository.toggleTraining`).
    func toggleTrainingDay() {
        if let message = environment.toggleTrainingDay(day) {
            errorMessage = message
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
        let message = entries.count == 1
            ? String(localized: "Deleted \(entries[0].displayName)") : String(localized: "Deleted \(entries.count) entries")
        offerUndo(message) { try $0.restore(entryIDs: ids) }
    }

    func duplicate(_ entry: DiaryEntry) {
        perform { _ = try $0.duplicate(entryID: entry.id) }
    }

    /// Moves a logged entry. Never to a future day: eaten food would count (and reach Apple Health) ahead of time.
    func move(_ entry: DiaryEntry, toSlot slotID: String, day targetDay: LocalDay? = nil) {
        let target = targetDay ?? entry.day
        guard target <= today || target <= entry.day else {
            errorMessage = String(localized: "Eaten food can't move to a future day. To have it then, plan it on that day.")
            return
        }
        perform { try $0.move(entryID: entry.id, toSlot: slotID, day: target) }
    }

    func reorder(in section: MealSection, from source: IndexSet, to destination: Int) {
        var ids = section.entries.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        perform { try $0.reorder(day: day, slotID: section.slot.id, orderedIDs: ids) }
    }

    // MARK: Meal plan

    func planned(in slotID: String) -> [PlannedEntry] {
        planned.filter { $0.mealSlotID == slotID }
    }

    var plannedTotals: Nutrients {
        Nutrients.sum(planned.map(\.nutrients))
    }

    /// "Eaten": logs the planned entries into the diary. Returns the new diary entry ids (nil on failure).
    @discardableResult
    func confirm(_ entries: [PlannedEntry]) -> [String]? {
        guard let repo = environment.mealPlan, !entries.isEmpty else { return nil }
        do {
            let ids = try repo.confirm(plannedIDs: entries.map(\.id))
            guard !ids.isEmpty else { return ids }
            let message = entries.count == 1
                ? String(localized: "Logged \(entries[0].displayName)") : String(localized: "Logged \(ids.count) planned entries")
            // Deleting the logged entries puts them back in the plan.
            offerUndo(message) { try $0.softDelete(entryIDs: ids) }
            return ids
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Confirms the plan of one slot, or of the whole day when `slotID` is nil.
    func confirmAll(slotID: String?) {
        confirm(slotID.map(planned(in:)) ?? planned)
    }

    /// "Eaten, different amount": logs the plan and returns the new entry for editing.
    func confirmForEditing(_ entry: PlannedEntry) -> DiaryEntry? {
        guard let id = confirm([entry])?.first else { return nil }
        return try? environment.diary?.entry(id: id)
    }

    func deletePlanned(_ entries: [PlannedEntry]) {
        let ids = entries.map(\.id)
        guard !ids.isEmpty, performPlan({ try $0.softDelete(plannedIDs: ids) }) else { return }
        let message = entries.count == 1
            ? String(localized: "Removed \(entries[0].displayName) from the plan")
            : String(localized: "Removed \(entries.count) planned entries")
        let generation = environment.dataGeneration
        undo.offer(message) { [weak self] in
            guard let self, environment.dataGeneration == generation else { return }
            performPlan { try $0.restore(plannedIDs: ids) }
        }
    }

    func movePlanned(_ entry: PlannedEntry, toSlot slotID: String, day targetDay: LocalDay? = nil) {
        performPlan { try $0.move(plannedID: entry.id, toSlot: slotID, day: targetDay ?? entry.day) }
    }

    // MARK: Copy (backlog #12)

    /// Copies one meal (or the whole day when `slotID` is nil) from `source` into the current day. A future day gets
    /// it as a plan, so nothing counts as eaten ahead of time.
    func copy(from source: LocalDay, slotID: String?) {
        if isFuture {
            copyIntoPlan(from: source, slotID: slotID)
            return
        }
        guard let repo = environment.diary else { return }
        do {
            let ids = try repo.copy(from: source, slotID: slotID, to: day)
            guard !ids.isEmpty else {
                errorMessage = Self.nothingToCopy(source, today: today, slotID: slotID)
                return
            }
            offerUndo(String(localized: "Copied \(ids.count) entries")) { try $0.softDelete(entryIDs: ids) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyIntoPlan(from source: LocalDay, slotID: String?) {
        guard let repo = environment.mealPlan else { return }
        do {
            let ids = try repo.copyToPlan(from: source, slotID: slotID, to: day)
            guard !ids.isEmpty else {
                errorMessage = Self.nothingToCopy(source, today: today, slotID: slotID)
                return
            }
            let generation = environment.dataGeneration
            undo.offer(String(localized: "Planned \(ids.count) entries")) { [weak self] in
                guard let self, environment.dataGeneration == generation else { return }
                performPlan { try $0.softDelete(plannedIDs: ids) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func nothingToCopy(_ source: LocalDay, today: LocalDay, slotID: String?) -> String {
        let day = Format.day(source, today: today)
        return slotID == nil
            ? String(localized: "Nothing to copy — \(day) has no entries.")
            : String(localized: "Nothing to copy — \(day) has no entries in that meal.")
    }

    // MARK: Saved meals (backlog #32)

    /// "Save as meal": a saved meal from the food entries of one slot of the current day.
    @discardableResult
    func saveAsMeal(slotID: String, name: String) -> Bool {
        guard let meals = environment.meals else { return false }
        do {
            let meal = try meals.createFromDiary(day: day, slotID: slotID, name: name)
            undo.offer(String(localized: "Saved meal “\(meal.template.name)”")) { [weak self] in
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
    private func performPlan(_ action: (MealPlanRepository) throws -> Void) -> Bool {
        guard let repo = environment.mealPlan else { return false }
        do {
            try action(repo)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
            return String(localized: """
            \(unit.format(kcal)) is less than half of your estimated \(unit.format(estimateKcal)) a day. \
            If something is missing, add it. If this really was everything, mark the day as fully logged.
            """)
        }
        if entryCount < AdaptiveTDEE.minimumEntries {
            return String(localized: """
            Days with fewer than \(AdaptiveTDEE.minimumEntries) entries are left out of the maintenance estimate. \
            Mark the day as fully logged if this was everything you ate.
            """)
        }
        return nil
    }
}
