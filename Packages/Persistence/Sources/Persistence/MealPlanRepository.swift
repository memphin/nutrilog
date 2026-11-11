import Core
import Foundation
import GRDB

/// A food planned for a day and meal slot (meal plan / meal prep). It is not eaten until it is confirmed: only then a
/// real `DiaryEntry` is logged, so a plan never counts in day totals, the TDEE estimate, Apple Health or exports.
public struct PlannedEntry: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "planned_entry"

    public var id: String
    public var day: LocalDay
    public var mealSlotID: String
    public var foodID: String?
    public var displayName: String
    /// Amount in the food's base unit (g or ml); 0 for quick-add.
    public var grams: Double
    public var servingLabel: String?
    public var isQuickAdd: Bool
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double?
    public var sugarG: Double?
    public var satFatG: Double?
    public var sodiumMg: Double?
    public var sortOrder: Int
    /// The diary entry logged when the plan was confirmed. The plan counts as eaten only while that entry is active.
    public var eatenEntryID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, grams, kcal, revision
        case mealSlotID = "meal_slot_id"
        case foodID = "food_id"
        case displayName = "display_name"
        case servingLabel = "serving_label"
        case isQuickAdd = "is_quick_add"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case satFatG = "sat_fat_g"
        case sodiumMg = "sodium_mg"
        case sortOrder = "sort_order"
        case eatenEntryID = "eaten_entry_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    init(
        id: String = newID(), day: LocalDay, mealSlotID: String, foodID: String?, displayName: String,
        grams: Double, servingLabel: String?, isQuickAdd: Bool, nutrients: Nutrients, sortOrder: Int, now: Date,
    ) {
        self.id = id
        self.day = day
        self.mealSlotID = mealSlotID
        self.foodID = foodID
        self.displayName = displayName
        self.grams = grams
        self.servingLabel = servingLabel
        self.isQuickAdd = isQuickAdd
        kcal = nutrients.kcal
        proteinG = nutrients.proteinG
        carbsG = nutrients.carbsG
        fatG = nutrients.fatG
        fiberG = nutrients.fiberG
        sugarG = nutrients.sugarG
        satFatG = nutrients.satFatG
        sodiumMg = nutrients.sodiumMg
        self.sortOrder = sortOrder
        createdAt = now
        updatedAt = now
        revision = 1
    }

    /// The planned amount's nutrients (an estimate until confirmed).
    public var nutrients: Nutrients {
        get {
            Nutrients(
                kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                fiberG: fiberG, sugarG: sugarG, satFatG: satFatG, sodiumMg: sodiumMg,
            )
        }
        set {
            kcal = newValue.kcal
            proteinG = newValue.proteinG
            carbsG = newValue.carbsG
            fatG = newValue.fatG
            fiberG = newValue.fiberG
            sugarG = newValue.sugarG
            satFatG = newValue.satFatG
            sodiumMg = newValue.sodiumMg
        }
    }
}

/// One line of the meal-prep list: everything planned of one food over a range of days.
public struct PrepItem: Hashable, Sendable, Identifiable {
    /// The food id, or `quick:<name>` for quick-adds.
    public var id: String
    public var foodID: String?
    public var name: String
    public var isQuickAdd: Bool
    /// Total amount in the food's base unit (g or ml); 0 for quick-adds.
    public var totalGrams: Double
    /// Number of planned portions.
    public var portions: Int
    /// The days it is planned on, oldest first, without repeats.
    public var days: [LocalDay]
    public var nutrients: Nutrients
}

/// Meal plan for the coming days: plan foods, confirm them into the diary when eaten, and sum them up for meal prep.
public struct MealPlanRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Reads

    /// Planned entries of `days` that are not eaten yet, by day, then slot order, then position.
    public func pending(in days: ClosedRange<LocalDay>) throws -> [PlannedEntry] {
        try database.reader.read { db in try Self.pending(db, in: days) }
    }

    public func pending(for day: LocalDay) throws -> [PlannedEntry] {
        try pending(in: day ... day)
    }

    /// Emits the pending plan of `days` now and after every change (including diary changes that un-eat a plan).
    public func observePending(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[PlannedEntry]> {
        ValueObservation
            .tracking { db in try Self.pending(db, in: days) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    public func entry(id: String) throws -> PlannedEntry? {
        try database.reader.read { db in try PlannedEntry.fetchOne(db, key: id) }
    }

    // MARK: Planning

    /// Plans `quantity` of `food`, estimating nutrients from the food's current per-100 values.
    @discardableResult
    public func plan(food: Food, quantity: Quantity, slotID: String, day: LocalDay) throws -> PlannedEntry {
        try planAll([.init(food: food, quantity: quantity)], slotID: slotID, day: day)[0]
    }

    /// Plans several foods into one slot in a single transaction (a saved meal, a smart-log result).
    @discardableResult
    public func planAll(_ items: [DiaryRepository.LogItem], slotID: String, day: LocalDay) throws -> [PlannedEntry] {
        guard !items.isEmpty, items.allSatisfy({ $0.quantity.baseAmount > 0 }) else {
            throw PersistenceError.validation("amount must be greater than zero")
        }
        let now = clock.now()
        return try database.writer.write { db in
            try items.map { item in
                let entry = try PlannedEntry(
                    day: day, mealSlotID: slotID, foodID: item.food.id, displayName: item.food.name,
                    grams: item.quantity.baseAmount, servingLabel: item.quantity.servingLabel, isQuickAdd: false,
                    nutrients: item.quantity.nutrients(per100: item.food.per100),
                    sortOrder: Self.nextSortOrder(db, day: day, slotID: slotID), now: now,
                )
                try entry.insert(db)
                return entry
            }
        }
    }

    /// Plans calories (and optional macros) without a food.
    @discardableResult
    public func planQuickAdd(name: String?, nutrients: Nutrients, slotID: String, day: LocalDay) throws -> PlannedEntry {
        let now = clock.now()
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try database.writer.write { db in
            let entry = try PlannedEntry(
                day: day, mealSlotID: slotID, foodID: nil, displayName: title.isEmpty ? "Quick add" : title,
                grams: 0, servingLabel: nil, isQuickAdd: true, nutrients: nutrients,
                sortOrder: Self.nextSortOrder(db, day: day, slotID: slotID), now: now,
            )
            try entry.insert(db)
            return entry
        }
    }

    /// Changes the planned amount of a food; the estimate is scaled like a diary entry's snapshot.
    public func updateQuantity(plannedID: String, quantity: Quantity) throws {
        guard quantity.baseAmount > 0 else { throw PersistenceError.validation("amount must be greater than zero") }
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try PlannedEntry.fetchOne(db, key: plannedID) else { throw PersistenceError.notFound(plannedID) }
            guard !entry.isQuickAdd else { throw PersistenceError.validation("quick-add entries have no quantity") }
            if entry.grams > 0 {
                entry.nutrients = entry.nutrients.scaled(by: quantity.baseAmount / entry.grams)
            } else if let foodID = entry.foodID, let food = try Food.fetchOne(db, key: foodID) {
                entry.nutrients = quantity.nutrients(per100: food.per100)
            } else {
                throw PersistenceError.validation("entry has no amount to scale")
            }
            entry.grams = quantity.baseAmount
            entry.servingLabel = quantity.servingLabel
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    /// Moves a planned entry to another slot and/or day; it goes to the end of the target slot.
    public func move(plannedID: String, toSlot slotID: String, day: LocalDay) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var entry = try PlannedEntry.fetchOne(db, key: plannedID) else { throw PersistenceError.notFound(plannedID) }
            guard entry.mealSlotID != slotID || entry.day != day else { return }
            entry.sortOrder = try Self.nextSortOrder(db, day: day, slotID: slotID)
            entry.mealSlotID = slotID
            entry.day = day
            entry.stampUpdated(now)
            try entry.update(db)
        }
    }

    public func softDelete(plannedIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for id in plannedIDs {
                guard var entry = try PlannedEntry.fetchOne(db, key: id), entry.deletedAt == nil else { continue }
                entry.stampDeleted(now)
                try entry.update(db)
            }
        }
    }

    /// Undo for `softDelete`.
    public func restore(plannedIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for id in plannedIDs {
                guard var entry = try PlannedEntry.fetchOne(db, key: id), entry.deletedAt != nil else { continue }
                entry.deletedAt = nil
                entry.stampUpdated(now)
                try entry.update(db)
            }
        }
    }

    // MARK: Confirming

    /// "Eaten": logs each pending planned entry into the diary on its own day and slot, and links it to the new entry.
    /// A food entry gets a fresh snapshot from the food's current values, like logging it now would; a quick-add, or a
    /// plan whose food is gone, keeps its estimate. Plans already eaten are skipped.
    /// Returns the new diary entry ids, in the order of `plannedIDs` (soft-delete them to undo).
    @discardableResult
    public func confirm(plannedIDs: [String]) throws -> [String] {
        let now = clock.now()
        return try database.writer.write { db in
            var created: [String] = []
            for id in plannedIDs {
                guard var planned = try PlannedEntry.fetchOne(db, key: id), planned.deletedAt == nil,
                      try !Self.isEaten(db, planned) else { continue }
                var displayName = planned.displayName
                var nutrients = planned.nutrients
                if !planned.isQuickAdd, let foodID = planned.foodID, var food = try Food.fetchOne(db, key: foodID),
                   food.deletedAt == nil
                {
                    displayName = food.name
                    nutrients = food.per100.scaled(toGrams: planned.grams)
                    food.useCount += 1
                    food.lastUsedAt = now
                    food.stampUpdated(now)
                    try food.update(db)
                }
                let entry = try DiaryEntry(
                    day: planned.day, mealSlotID: planned.mealSlotID, foodID: planned.foodID, displayName: displayName,
                    grams: planned.grams, servingLabel: planned.servingLabel, isQuickAdd: planned.isQuickAdd,
                    nutrients: nutrients, loggedAt: now,
                    sortOrder: DiaryRepository.nextSortOrder(db, day: planned.day, slotID: planned.mealSlotID),
                )
                try entry.insert(db)
                planned.eatenEntryID = entry.id
                planned.stampUpdated(now)
                try planned.update(db)
                created.append(entry.id)
            }
            try DiaryRepository.queueHealthWrite(db, ids: created, now: now)
            return created
        }
    }

    // MARK: Copy

    /// Plans what `sourceDay` holds (one slot, or every slot when `slotID` is nil) on each of `targetDays`: its
    /// active diary entries and its pending plan. Food entries are re-estimated from the food's current values.
    /// Returns the new planned ids (soft-delete them to undo).
    @discardableResult
    public func copyToPlan(
        from sourceDay: LocalDay, slotID: String? = nil, to targetDays: [LocalDay], targetSlotID: String? = nil,
    ) throws -> [String] {
        let now = clock.now()
        return try database.writer.write { db in
            var eaten = DiaryEntry.filter(DiaryEntry.Columns.day == sourceDay && DiaryEntry.Columns.deletedAt == nil)
            if let slotID {
                eaten = eaten.filter(DiaryEntry.Columns.mealSlotID == slotID)
            }
            let logged = try eaten.order(DiaryEntry.Columns.mealSlotID, DiaryEntry.Columns.sortOrder).fetchAll(db)
            let planned = try Self.pending(db, in: sourceDay ... sourceDay).filter { slotID == nil || $0.mealSlotID == slotID }
            let sources = logged.map(Source.init(entry:)) + planned.map(Source.init(planned:))
            var created: [String] = []
            for day in targetDays {
                for source in sources {
                    let slot = targetSlotID ?? source.slotID
                    var name = source.name
                    var nutrients = source.nutrients
                    if !source.isQuickAdd, let foodID = source.foodID,
                       let food = try Food.fetchOne(db, key: foodID), food.deletedAt == nil
                    {
                        name = food.name
                        nutrients = food.per100.scaled(toGrams: source.grams)
                    }
                    let entry = try PlannedEntry(
                        day: day, mealSlotID: slot, foodID: source.foodID, displayName: name, grams: source.grams,
                        servingLabel: source.servingLabel, isQuickAdd: source.isQuickAdd, nutrients: nutrients,
                        sortOrder: Self.nextSortOrder(db, day: day, slotID: slot), now: now,
                    )
                    try entry.insert(db)
                    created.append(entry.id)
                }
            }
            return created
        }
    }

    private struct Source {
        var slotID: String
        var foodID: String?
        var name: String
        var grams: Double
        var servingLabel: String?
        var isQuickAdd: Bool
        var nutrients: Nutrients

        init(entry: DiaryEntry) {
            slotID = entry.mealSlotID
            foodID = entry.foodID
            name = entry.displayName
            grams = entry.grams
            servingLabel = entry.servingLabel
            isQuickAdd = entry.isQuickAdd
            nutrients = entry.nutrients
        }

        init(planned: PlannedEntry) {
            slotID = planned.mealSlotID
            foodID = planned.foodID
            name = planned.displayName
            grams = planned.grams
            servingLabel = planned.servingLabel
            isQuickAdd = planned.isQuickAdd
            nutrients = planned.nutrients
        }
    }

    // MARK: Meal prep

    /// Sums planned entries per food (quick-adds per name), for cooking or shopping ahead. Sorted by name.
    public static func prepList(_ entries: [PlannedEntry]) -> [PrepItem] {
        var items: [String: PrepItem] = [:]
        var order: [String] = []
        for entry in entries {
            let key = entry.foodID ?? "quick:\(entry.displayName.lowercased())"
            if var item = items[key] {
                item.totalGrams += entry.grams
                item.portions += 1
                if !item.days.contains(entry.day) {
                    item.days.append(entry.day)
                }
                item.nutrients = Nutrients.sum([item.nutrients, entry.nutrients])
                items[key] = item
            } else {
                order.append(key)
                items[key] = PrepItem(
                    id: key, foodID: entry.foodID, name: entry.displayName, isQuickAdd: entry.isQuickAdd,
                    totalGrams: entry.grams, portions: 1, days: [entry.day], nutrients: entry.nutrients,
                )
            }
        }
        return order.compactMap { items[$0] }
            .map { item in
                var item = item
                item.days.sort()
                return item
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helpers

    static func pending(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [PlannedEntry] {
        try PlannedEntry.fetchAll(db, sql: """
        SELECT p.* FROM planned_entry p
        LEFT JOIN diary_entry e ON e.id = p.eaten_entry_id AND e.deleted_at IS NULL
        LEFT JOIN meal_slot s ON s.id = p.meal_slot_id
        WHERE p.deleted_at IS NULL AND e.id IS NULL AND p.day >= ? AND p.day <= ?
        ORDER BY p.day, s.sort_order, p.sort_order, p.created_at
        """, arguments: [days.lowerBound, days.upperBound])
    }

    static func isEaten(_ db: Database, _ planned: PlannedEntry) throws -> Bool {
        guard let id = planned.eatenEntryID else { return false }
        return try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM diary_entry WHERE id = ? AND deleted_at IS NULL)
        """, arguments: [id]) ?? false
    }

    static func nextSortOrder(_ db: Database, day: LocalDay, slotID: String) throws -> Int {
        let max = try Int.fetchOne(db, sql: """
        SELECT MAX(sort_order) FROM planned_entry WHERE day = ? AND meal_slot_id = ?
        """, arguments: [day, slotID])
        return (max ?? -1) + 1
    }
}
