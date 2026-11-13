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

/// A day's diary in one row: totals, number of entries and the "fully logged" mark.
public struct DiaryDaySummary: Hashable, Sendable {
    public var day: LocalDay
    public var totals: Nutrients
    public var entryCount: Int
    public var isComplete: Bool

    public init(day: LocalDay, totals: Nutrients, entryCount: Int, isComplete: Bool) {
        self.day = day
        self.totals = totals
        self.entryCount = entryCount
        self.isComplete = isComplete
    }
}

/// The name a quick-add entry (diary or plan) gets when the user gives none. It is stored with the entry in the
/// app's language at log time, so entries from before a language change keep the English (or other) name.
public enum QuickAddName {
    /// The default name in the app's current language.
    public static var `default`: String {
        String(localized: "Quick add", bundle: .module, comment: "Name of a quick-add entry the user didn't name")
    }

    /// The name the user typed, trimmed; the default name when they typed none.
    static func name(typed name: String?) -> String {
        name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.nonBlank ?? self.default
    }

    /// Whether `name` is a default name (English or the current language) rather than one the user typed.
    public static func isDefault(_ name: String) -> Bool {
        name == "Quick add" || name == self.default
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
        database.observe { db in try Self.fetchDiary(db, day: day) }
    }

    public func entry(id: String) throws -> DiaryEntry? {
        try database.reader.read { db in try DiaryEntry.fetchOne(db, key: id) }
    }

    /// Totals for a day (active entries only).
    public func totals(for day: LocalDay) throws -> Nutrients {
        try diary(for: day).totals
    }

    // MARK: Day summaries (history, charts, adaptive TDEE)

    /// One row per day in `days` that has active entries or is marked as fully logged, oldest first.
    public func daySummaries(in days: ClosedRange<LocalDay>) throws -> [DiaryDaySummary] {
        try database.reader.read { db in try Self.daySummaries(db, in: days) }
    }

    public func observeDaySummaries(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[DiaryDaySummary]> {
        database.observe { db in try Self.daySummaries(db, in: days) }
    }

    // MARK: Caffeine

    /// Active entries with caffeine (`caffeine_mg > 0`) of every day in `days`, by `logged_at` — the diary's caffeine
    /// doses. ``CaffeineRepository/observeIntakes(in:)`` combines them with the caffeine quick-adds.
    public func caffeineIntakes(in days: ClosedRange<LocalDay>) throws -> [DiaryCaffeineIntake] {
        try database.reader.read { db in try Self.caffeineIntakes(db, in: days) }
    }

    static func caffeineIntakes(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [DiaryCaffeineIntake] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT id, day, logged_at, caffeine_mg, display_name FROM diary_entry
        WHERE caffeine_mg > 0 AND deleted_at IS NULL AND day >= ? AND day <= ?
        ORDER BY logged_at, id
        """, arguments: [days.lowerBound, days.upperBound])
        return rows.compactMap { row in
            // `logged_at` is ISO-8601 TEXT (see `Timestamp`); a row that doesn't parse can't be placed on the curve.
            guard let loggedAt = (row["logged_at"] as String?).flatMap(Timestamp.date) else { return nil }
            return DiaryCaffeineIntake(
                id: row["id"], day: row["day"], loggedAt: loggedAt, mg: row["caffeine_mg"], name: row["display_name"],
            )
        }
        // Text order can differ from time order when imported timestamps lack the fraction; sort by the parsed time.
        .sorted { ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id) }
    }

    static func daySummaries(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [DiaryDaySummary] {
        var result: [LocalDay: DiaryDaySummary] = [:]
        let rows = try Row.fetchAll(db, sql: """
        SELECT day, COUNT(*) AS entries, SUM(kcal) AS kcal, SUM(protein_g) AS protein_g, SUM(carbs_g) AS carbs_g,
               SUM(fat_g) AS fat_g, SUM(fiber_g) AS fiber_g, SUM(sugar_g) AS sugar_g, SUM(sat_fat_g) AS sat_fat_g,
               SUM(sodium_mg) AS sodium_mg, SUM(caffeine_mg) AS caffeine_mg
        FROM diary_entry WHERE deleted_at IS NULL AND day >= ? AND day <= ? GROUP BY day
        """, arguments: [days.lowerBound, days.upperBound])
        for row in rows {
            let day: LocalDay = row["day"]
            result[day] = DiaryDaySummary(
                day: day,
                totals: Nutrients(
                    kcal: row["kcal"], proteinG: row["protein_g"], carbsG: row["carbs_g"], fatG: row["fat_g"],
                    fiberG: row["fiber_g"], sugarG: row["sugar_g"], satFatG: row["sat_fat_g"], sodiumMg: row["sodium_mg"],
                    caffeineMg: row["caffeine_mg"],
                ),
                entryCount: row["entries"], isComplete: false,
            )
        }
        let complete = try LocalDay.fetchAll(db, sql: """
        SELECT day FROM day_note WHERE deleted_at IS NULL AND is_complete = 1 AND day >= ? AND day <= ?
        """, arguments: [days.lowerBound, days.upperBound])
        for day in complete {
            result[day, default: DiaryDaySummary(day: day, totals: .zero, entryCount: 0, isComplete: true)].isComplete = true
        }
        return result.values.sorted { $0.day < $1.day }
    }

    // MARK: Logging

    /// Logs `quantity` of `food`, snapshotting nutrients from the food's current per-100 values.
    /// Also records the food's use (`use_count`, `last_used_at`, last quantity).
    @discardableResult
    public func log(
        food: Food, quantity: Quantity, servingID: String? = nil, slotID: String, day: LocalDay,
    ) throws -> DiaryEntry {
        guard quantity.baseAmount > 0 else { throw PersistenceError.amountNotPositive }
        try EntryLimits.validate(amount: quantity.baseAmount)
        let now = clock.now()
        return try database.writer.write { db in
            try Self.insertFoodEntry(db, food: food, quantity: quantity, servingID: servingID, slotID: slotID, day: day, now: now)
        }
    }

    /// One food to log with ``logAll(_:slotID:day:)``.
    public struct LogItem: Sendable {
        public var food: Food
        public var quantity: Quantity
        public var servingID: String?

        public init(food: Food, quantity: Quantity, servingID: String? = nil) {
            self.food = food
            self.quantity = quantity
            self.servingID = servingID
        }
    }

    /// Logs several foods into one slot in a single transaction (saved meals, backlog #32): all or nothing.
    @discardableResult
    public func logAll(_ items: [LogItem], slotID: String, day: LocalDay) throws -> [DiaryEntry] {
        guard items.allSatisfy({ $0.quantity.baseAmount > 0 }) else {
            throw PersistenceError.amountNotPositive
        }
        for item in items {
            try EntryLimits.validate(amount: item.quantity.baseAmount)
        }
        let now = clock.now()
        return try database.writer.write { db in
            try items.map { item in
                try Self.insertFoodEntry(
                    db, food: item.food, quantity: item.quantity, servingID: item.servingID, slotID: slotID, day: day, now: now,
                )
            }
        }
    }

    /// The fluid (ml) an entry of `baseAmount` g/ml of `food` counts toward hydration, snapshotted like its nutrients:
    /// `baseAmount` when the food counts as fluid (Core `FluidRule`, with the food's override), nil when it doesn't or
    /// there is no amount. A solid food the user marked as a drink counts its grams as ml.
    public static func fluidMl(for food: Food, baseAmount: Double) -> Double? {
        guard baseAmount > 0,
              FluidRule.counts(isLiquid: food.isLiquid, fatPer100: food.per100.fatG, override: food.countsAsFluid)
        else { return nil }
        return baseAmount
    }

    /// Inserts one food entry with a snapshot of `food`'s per-100 values and its fluid (``fluidMl(for:baseAmount:)``),
    /// queues its Health write and records the food's use. A soft-deleted food (an item of a saved meal) is still
    /// logged; only its use isn't recorded.
    static func insertFoodEntry(
        _ db: Database, food: Food, quantity: Quantity, servingID: String?, slotID: String, day: LocalDay, now: Date,
    ) throws -> DiaryEntry {
        try EntryLimits.validate(amount: quantity.baseAmount) // also covers saved meals logged through here
        let nutrients = quantity.nutrients(per100: food.per100)
        try EntryLimits.validateFinite(nutrients)
        guard var stored = try Food.fetchOne(db, key: food.id) else { throw PersistenceError.notFound(food.id) }
        var entry = try DiaryEntry(
            day: day, mealSlotID: slotID, foodID: food.id, displayName: food.name,
            grams: quantity.baseAmount, servingLabel: quantity.servingLabel, isQuickAdd: false,
            nutrients: nutrients, loggedAt: now,
            sortOrder: DiaryEntry.nextSortOrder(db, day: day, slotID: slotID),
        )
        entry.fluidMl = fluidMl(for: food, baseAmount: quantity.baseAmount)
        try entry.insert(db)
        try queueHealthWrite(db, ids: [entry.id], now: now)

        if stored.deletedAt == nil {
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
        }
        entry.revision = 1
        return entry
    }

    /// Quick-add calories (and optional macros) without a food (FR-5, backlog #10).
    @discardableResult
    public func logQuickAdd(name: String?, nutrients: Nutrients, slotID: String, day: LocalDay) throws -> DiaryEntry {
        try EntryLimits.validate(nutrients)
        let now = clock.now()
        return try database.writer.write { db in
            let entry = try DiaryEntry(
                day: day, mealSlotID: slotID, foodID: nil, displayName: QuickAddName.name(typed: name),
                grams: 0, servingLabel: nil, isQuickAdd: true, nutrients: nutrients, loggedAt: now,
                sortOrder: DiaryEntry.nextSortOrder(db, day: day, slotID: slotID),
            )
            try entry.insert(db)
            try Self.queueHealthWrite(db, ids: [entry.id], now: now)
            return entry
        }
    }

    // MARK: Edits

    /// Changes the amount of a food entry. The existing snapshot (nutrients and fluid) is scaled, so later edits to
    /// the food never leak into history (NFR-4).
    public func updateQuantity(entryID: String, quantity: Quantity) throws {
        guard quantity.baseAmount > 0 else { throw PersistenceError.amountNotPositive }
        try EntryLimits.validate(amount: quantity.baseAmount)
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            guard !entry.isQuickAdd else { throw PersistenceError.quickAddHasNoQuantity }
            let newAmount = quantity.baseAmount
            // A 0 g entry (legacy or imported) has no ratio to scale; re-reading the food would leak later edits
            // into history (NFR-4), so it can't be resized — log it again instead.
            guard entry.grams > 0 else { throw PersistenceError.nothingToScale }
            entry.nutrients = entry.nutrients.scaled(by: newAmount / entry.grams)
            entry.fluidMl = entry.fluidMl.map { $0 * newAmount / entry.grams }
            entry.grams = newAmount
            entry.servingLabel = quantity.servingLabel
            entry.stampUpdated(now)
            try entry.update(db)
            try Self.queueHealthWrite(db, ids: [entry.id], now: now)
        }
    }

    /// Edits a quick-add entry's name and nutrients.
    public func updateQuickAdd(entryID: String, name: String?, nutrients: Nutrients) throws {
        try EntryLimits.validate(nutrients)
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try DiaryEntry.fetchOne(db, key: entryID) else { throw PersistenceError.notFound(entryID) }
            guard entry.isQuickAdd else { throw PersistenceError.validation(String(localized: "not a quick-add entry", bundle: .module)) }
            entry.displayName = QuickAddName.name(typed: name)
            entry.nutrients = nutrients
            entry.stampUpdated(now)
            try entry.update(db)
            try Self.queueHealthWrite(db, ids: [entry.id], now: now)
        }
    }

    /// Moves an entry to another slot and/or day; it goes to the end of the target slot.
    public func move(entryID: String, toSlot slotID: String, day: LocalDay) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard try DiaryEntry.move(db, id: entryID, toSlot: slotID, day: day, now: now) else { return }
            try Self.queueHealthWrite(db, ids: [entryID], now: now) // the sample's date follows the day
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
            copy.sortOrder = try DiaryEntry.nextSortOrder(db, day: source.day, slotID: source.mealSlotID)
            copy.stampCreated(now)
            try copy.insert(db)
            try Self.queueHealthWrite(db, ids: [copy.id], now: now)
            return copy
        }
    }

    // MARK: Delete / undo

    public func softDelete(entryIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            let changed = try DiaryEntry.softDelete(db, ids: entryIDs, now: now)
            try Self.queueHealthWrite(db, ids: changed, now: now)
        }
    }

    /// Undo for `softDelete` (the 5-second snackbar, backlog #7).
    public func restore(entryIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            let changed = try DiaryEntry.restore(db, ids: entryIDs, now: now) { db, entry in
                // Its old position may have been taken since: it goes to the end of the slot then.
                let taken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM diary_entry
                WHERE day = ? AND meal_slot_id = ? AND sort_order = ? AND deleted_at IS NULL AND id != ?)
                """, arguments: [entry.day, entry.mealSlotID, entry.sortOrder, entry.id]) ?? false
                if taken {
                    entry.sortOrder = try DiaryEntry.nextSortOrder(db, day: entry.day, slotID: entry.mealSlotID)
                }
            }
            try Self.queueHealthWrite(db, ids: changed, now: now)
        }
    }

    // MARK: Copy (backlog #12)

    /// Copies entries of `sourceDay` (one slot, or all slots when `slotID` is nil) to `targetDay`
    /// (into `targetSlotID`, or the same slots). Food entries get a fresh snapshot (nutrients and fluid) from the
    /// food's *current* values; quick-adds and entries whose food was deleted keep their snapshot.
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
                copy.sortOrder = try DiaryEntry.nextSortOrder(db, day: targetDay, slotID: slot)
                // A 0 g entry (legacy or imported) has no amount to re-snapshot: it keeps its own snapshot and name.
                if !source.isQuickAdd, source.grams > 0, let foodID = source.foodID,
                   let food = try Food.fetchOne(db, key: foodID), food.deletedAt == nil
                {
                    copy.nutrients = food.per100.scaled(toGrams: source.grams)
                    copy.fluidMl = Self.fluidMl(for: food, baseAmount: source.grams)
                    copy.displayName = food.name
                }
                copy.stampCreated(now)
                try copy.insert(db)
                created.append(copy.id)
            }
            try Self.queueHealthWrite(db, ids: created, now: now)
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

    /// Queues entries for the Apple Health writer (backlog #27) in the same transaction as their change, so the
    /// nutrient samples follow every save, edit, move, delete and undo. Notes and reordering don't touch Health.
    static func queueHealthWrite(_ db: Database, ids: [String], now: Date) throws {
        try HealthKitLinkRepository.enqueue(db, owner: .diaryEntry, ids: ids, now: now)
    }

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
}
