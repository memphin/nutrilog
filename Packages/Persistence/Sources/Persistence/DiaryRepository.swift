import Core
import Foundation
import GRDB

/// One day of the diary: slots with their entries, totals and the day note.
public struct DayDiary: Hashable, Sendable {
    public struct Section: Hashable, Sendable, Identifiable {
        public var slot: MealSlot
        public var entries: [DiaryEntry]
        public var id: String {
            slot.id
        }

        public var totals: Nutrients {
            Nutrients.sum(entries.map(\.nutrients))
        }
    }

    public var day: LocalDay
    public var sections: [Section]
    public var note: DayNote?

    public var totals: Nutrients {
        Nutrients.sum(sections.map(\.totals))
    }

    public var entryCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }
}

/// Diary entries: logging with nutrient snapshots, edits, moves, soft deletes, copy meal/day
/// and day notes (backlog #3, #10, #12).
public struct DiaryRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Reads

    /// Active meal slots in display order.
    public func mealSlots(includeInactive: Bool = false) throws -> [MealSlot] {
        try database.reader.read { db in try Self.mealSlots(db, includeInactive: includeInactive) }
    }

    public func diary(for day: LocalDay) throws -> DayDiary {
        try database.reader.read { db in try Self.fetchDiary(db, day: day) }
    }

    /// Emits the day's diary now and after every change (backlog #3 — `ValueObservation`).
    public func observeDiary(for day: LocalDay) -> AsyncValueObservation<DayDiary> {
        ValueObservation
            .tracking { db in try Self.fetchDiary(db, day: day) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    public func entry(id: String) throws -> DiaryEntry? {
        try database.reader.read { db in try DiaryEntry.fetchOne(db, key: id) }
    }

    /// Totals for a day (active entries only).
    public func totals(for day: LocalDay) throws -> Nutrients {
        try diary(for: day).totals
    }

    // MARK: Logging

    /// Logs `quantity` of `food`, snapshotting nutrients from the food's current per-100 values.
    /// Also records the food's use (`use_count`, `last_used_at`, last quantity).
    @discardableResult
    public func log(
        food: Food, quantity: Quantity, servingID: String? = nil, slotID: String, day: LocalDay,
    ) throws -> DiaryEntry {
        guard quantity.baseAmount > 0 else { throw PersistenceError.validation("amount must be greater than zero") }
        let now = clock.now()
        return try database.writer.write { db in
            var entry = try DiaryEntry(
                day: day, mealSlotID: slotID, foodID: food.id, displayName: food.name,
                grams: quantity.baseAmount, servingLabel: quantity.servingLabel, isQuickAdd: false,
                nutrients: quantity.nutrients(per100: food.per100), loggedAt: now,
                sortOrder: Self.nextSortOrder(db, day: day, slotID: slotID),
            )
            try entry.insert(db)

            guard var stored = try Food.fetchOne(db, key: food.id) else { throw PersistenceError.notFound(food.id) }
            stored.useCount += 1
            stored.lastUsedAt = now
            switch quantity {
            case let .base(amount):
                stored.lastServingID = nil
                stored.lastAmount = amount
            case let .servings(count, _):
                stored.lastServingID = servingID
                stored.lastAmount = servingID == nil ? quantity.baseAmount : count
            }
            stored.stampUpdated(now)
            try stored.update(db)
            entry.revision = 1
            return entry
        }
    }

    /// Quick-add calories (and optional macros) without a food (FR-5, backlog #10).
    @discardableResult
    public func logQuickAdd(name: String?, nutrients: Nutrients, slotID: String, day: LocalDay) throws -> DiaryEntry {
        let now = clock.now()
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.writer.write { db in
            let entry = try DiaryEntry(
                day: day, mealSlotID: slotID, foodID: nil,
                displayName: (title?.isEmpty ?? true) ? "Quick add" : title!,
                grams: 0, servingLabel: nil, isQuickAdd: true, nutrients: nutrients, loggedAt: now,
                sortOrder: Self.nextSortOrder(db, day: day, slotID: slotID),
            )
            try entry.insert(db)
            return entry
        }
    }

    // MARK: Edits

    /// Changes the amount of a food entry. The existing snapshot is scaled, so later edits to the food
    /// never leak into history (NFR-4).
    public func updateQuantity(entryID: String, quantity: Quantity) throws {
        guard quantity.baseAmount > 0 else { throw PersistenceError.validation("amount must be greater than zero") }
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            guard !entry.isQuickAdd else { throw PersistenceError.validation("quick-add entries have no quantity") }
            let newAmount = quantity.baseAmount
            if entry.grams > 0 {
                entry.nutrients = entry.nutrients.scaled(by: newAmount / entry.grams)
            } else if let foodID = entry.foodID, let food = try Food.fetchOne(db, key: foodID) {
                entry.nutrients = quantity.nutrients(per100: food.per100)
            }
            entry.grams = newAmount
            entry.servingLabel = quantity.servingLabel
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    /// Edits a quick-add entry's name and nutrients.
    public func updateQuickAdd(entryID: String, name: String?, nutrients: Nutrients) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            guard entry.isQuickAdd else { throw PersistenceError.validation("not a quick-add entry") }
            let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.displayName = (title?.isEmpty ?? true) ? "Quick add" : title!
            entry.nutrients = nutrients
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    public func setNote(entryID: String, note: String?) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            entry.note = (note?.isEmpty ?? true) ? nil : note
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    /// Moves an entry to another slot and/or day; it goes to the end of the target slot.
    public func move(entryID: String, toSlot slotID: String, day: LocalDay) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            guard entry.mealSlotID != slotID || entry.day != day else { return }
            entry.sortOrder = try Self.nextSortOrder(db, day: day, slotID: slotID)
            entry.mealSlotID = slotID
            entry.day = day
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    /// Applies a new order to the entries of one slot. IDs not in the slot are ignored.
    public func reorder(day: LocalDay, slotID: String, orderedIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for (index, id) in orderedIDs.enumerated() {
                guard var entry = try DiaryEntry.fetchOne(db, key: id),
                      entry.day == day, entry.mealSlotID == slotID, entry.sortOrder != index else { continue }
                entry.sortOrder = index
                entry.stampUpdated(now)
                try entry.update(db)
            }
        }
    }

    /// Duplicates an entry within the same slot (same snapshot, fresh id).
    @discardableResult
    public func duplicate(entryID: String) throws -> DiaryEntry {
        let now = clock.now()
        return try database.writer.write { db in
            guard let source = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            var copy = source
            copy.id = newID()
            copy.loggedAt = now
            copy.sortOrder = try Self.nextSortOrder(db, day: source.day, slotID: source.mealSlotID)
            copy.stampCreated(now)
            try copy.insert(db)
            return copy
        }
    }

    // MARK: Delete / undo

    public func softDelete(entryIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for id in entryIDs {
                guard var entry = try DiaryEntry.fetchOne(db, key: id), entry.deletedAt == nil else { continue }
                entry.stampDeleted(now)
                try entry.update(db)
            }
        }
    }

    /// Undo for `softDelete` (the 5-second snackbar, backlog #7).
    public func restore(entryIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for id in entryIDs {
                guard var entry = try DiaryEntry.fetchOne(db, key: id), entry.deletedAt != nil else { continue }
                entry.deletedAt = nil
                entry.stampUpdated(now)
                try entry.update(db)
            }
        }
    }

    // MARK: Copy (backlog #12)

    /// Copies entries of `sourceDay` (one slot, or all slots when `slotID` is nil) to `targetDay`
    /// (into `targetSlotID`, or the same slots). Food entries get a fresh snapshot from the food's
    /// *current* values; quick-adds and entries whose food was deleted keep their snapshot.
    /// Returns the new entry ids (pass them to `softDelete` to undo).
    @discardableResult
    public func copy(
        from sourceDay: LocalDay,
        slotID: String? = nil,
        to targetDay: LocalDay,
        targetSlotID: String? = nil,
    ) throws -> [String] {
        let now = clock.now()
        return try database.writer.write { db in
            var request = DiaryEntry.filter(DiaryEntry.Columns.day == sourceDay && DiaryEntry.Columns.deletedAt == nil)
            if let slotID {
                request = request.filter(DiaryEntry.Columns.mealSlotID == slotID)
            }
            let sources = try request.order(DiaryEntry.Columns.mealSlotID, DiaryEntry.Columns.sortOrder).fetchAll(db)
            var created: [String] = []
            for source in sources {
                let slot = targetSlotID ?? source.mealSlotID
                var copy = source
                copy.id = newID()
                copy.day = targetDay
                copy.mealSlotID = slot
                copy.loggedAt = now
                copy.note = nil
                copy.sortOrder = try Self.nextSortOrder(db, day: targetDay, slotID: slot)
                if !source.isQuickAdd, let foodID = source.foodID,
                   let food = try Food.fetchOne(db, key: foodID), food.deletedAt == nil
                {
                    copy.nutrients = food.per100.scaled(toGrams: source.grams)
                    copy.displayName = food.name
                }
                copy.stampCreated(now)
                try copy.insert(db)
                created.append(copy.id)
            }
            return created
        }
    }

    // MARK: Day note

    public func note(for day: LocalDay) throws -> DayNote? {
        try database.reader.read { db in try DayNote.filter(key: day).filter(DayNote.Columns.deletedAt == nil).fetchOne(db) }
    }

    /// Sets the free-text note and/or "day fully logged" flag (FR-7). Empty text and not complete removes it.
    public func setDayNote(day: LocalDay, text: String, isComplete: Bool = false) throws {
        let now = clock.now()
        try database.writer.write { db in
            if var note = try DayNote.fetchOne(db, key: day) {
                note.text = text
                note.isComplete = isComplete
                if text.isEmpty, !isComplete {
                    note.deletedAt = now
                } else {
                    note.deletedAt = nil
                }
                note.stampUpdated(now)
                try note.update(db)
            } else if !text.isEmpty || isComplete {
                try DayNote(day: day, text: text, isComplete: isComplete, createdAt: now, updatedAt: now, revision: 1).insert(db)
            }
        }
    }

    // MARK: Helpers

    static func mealSlots(_ db: Database, includeInactive: Bool) throws -> [MealSlot] {
        var request = MealSlot.filter(MealSlot.Columns.deletedAt == nil)
        if !includeInactive {
            request = request.filter(MealSlot.Columns.isActive == true)
        }
        return try request.order(MealSlot.Columns.sortOrder).fetchAll(db)
    }

    static func fetchDiary(_ db: Database, day: LocalDay) throws -> DayDiary {
        let slots = try mealSlots(db, includeInactive: true)
        let entries = try DiaryEntry
            .filter(DiaryEntry.Columns.day == day && DiaryEntry.Columns.deletedAt == nil)
            .order(DiaryEntry.Columns.sortOrder, DiaryEntry.Columns.loggedAt)
            .fetchAll(db)
        let grouped = Dictionary(grouping: entries, by: \.mealSlotID)
        // Inactive slots are shown only when they still hold entries for this day.
        let sections = slots
            .filter { $0.isActive || grouped[$0.id] != nil }
            .map { DayDiary.Section(slot: $0, entries: grouped[$0.id] ?? []) }
        let note = try DayNote.filter(key: day).filter(DayNote.Columns.deletedAt == nil).fetchOne(db)
        return DayDiary(day: day, sections: sections, note: note)
    }

    static func nextSortOrder(_ db: Database, day: LocalDay, slotID: String) throws -> Int {
        let max = try Int.fetchOne(db, sql: """
        SELECT MAX(sort_order) FROM diary_entry WHERE day = ? AND meal_slot_id = ?
        """, arguments: [day, slotID])
        return (max ?? -1) + 1
    }
}
