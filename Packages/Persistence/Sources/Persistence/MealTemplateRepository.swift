import Core
import Foundation
import GRDB

/// A saved meal ("my usual breakfast", FR-24, backlog #32).
public struct MealTemplate: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "meal_template"

    public var id: String
    public var name: String
    /// The slot the meal was saved from; preselected nowhere, shown as a hint.
    public var mealSlotHint: String?
    public var useCount: Int
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name, revision
        case mealSlotHint = "meal_slot_hint"
        case useCount = "use_count"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

public struct MealTemplateItem: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "meal_template_item"

    public var id: String
    public var templateID: String
    public var foodID: String
    /// Amount in the food's base unit (g or ml).
    public var grams: Double
    public var servingID: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, grams, revision
        case templateID = "template_id"
        case foodID = "food_id"
        case servingID = "serving_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

/// A saved meal with its items and their foods.
public struct MealTemplateDetail: Hashable, Identifiable, Sendable {
    public struct Item: Hashable, Identifiable, Sendable {
        public var item: MealTemplateItem
        public var food: Food

        public var id: String {
            item.id
        }

        /// The food was deleted since the meal was saved. Its values are still known, so the item can be logged.
        public var isFoodDeleted: Bool {
            food.deletedAt != nil
        }

        /// Nutrients of the saved amount at the food's current values.
        public var nutrients: Nutrients {
            food.per100.scaled(toGrams: item.grams)
        }
    }

    public var template: MealTemplate
    public var items: [Item]

    public var id: String {
        template.id
    }

    public var totals: Nutrients {
        Nutrients.sum(items.map(\.nutrients))
    }

    public var hasDeletedFoods: Bool {
        items.contains(where: \.isFoodDeleted)
    }
}

/// Saved meals: create (from scratch or from a logged meal), list by use, log in one transaction.
public struct MealTemplateRepository: Sendable {
    /// A food and amount for a new or edited meal.
    public struct NewItem: Hashable, Sendable {
        public var foodID: String
        public var grams: Double
        public var servingID: String?

        public init(foodID: String, grams: Double, servingID: String? = nil) {
            self.foodID = foodID
            self.grams = grams
            self.servingID = servingID
        }
    }

    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Writes

    @discardableResult
    public func create(name: String, slotHint: String? = nil, items: [NewItem]) throws -> MealTemplateDetail {
        let now = clock.now()
        return try database.writer.write { db in try Self.create(db, name: name, slotHint: slotHint, items: items, now: now) }
    }

    /// "Save as meal": a template from the food entries of one meal of `day`. Quick-adds have no food and are left
    /// out; throws when the meal has no food entries.
    @discardableResult
    public func createFromDiary(day: LocalDay, slotID: String, name: String) throws -> MealTemplateDetail {
        let now = clock.now()
        return try database.writer.write { db in
            let entries = try DiaryEntry
                .filter(DiaryEntry.Columns.day == day && DiaryEntry.Columns.mealSlotID == slotID)
                .filter(DiaryEntry.Columns.deletedAt == nil && DiaryEntry.Columns.isQuickAdd == false)
                .order(DiaryEntry.Columns.sortOrder, DiaryEntry.Columns.loggedAt)
                .fetchAll(db)
            var items: [NewItem] = []
            for entry in entries where entry.grams > 0 {
                guard let foodID = entry.foodID, try Food.fetchOne(db, key: foodID) != nil else { continue }
                items.append(NewItem(foodID: foodID, grams: entry.grams))
            }
            return try Self.create(db, name: name, slotHint: slotID, items: items, now: now)
        }
    }

    public func rename(id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersistenceError.validation("A meal needs a name.") }
        let now = clock.now()
        try database.writer.write { db in
            guard var template = try MealTemplate.fetchOne(db, key: id) else { throw PersistenceError.notFound(id) }
            guard template.name != name else { return }
            template.name = name
            template.stampUpdated(now)
            try template.update(db)
        }
    }

    /// Replaces the meal's items (amount changes, removed foods).
    public func setItems(id: String, items: [NewItem]) throws {
        let valid = items.filter { $0.grams > 0 && $0.grams.isFinite }
        guard !valid.isEmpty else { throw PersistenceError.validation("A meal needs at least one food.") }
        let now = clock.now()
        try database.writer.write { db in
            guard var template = try MealTemplate.fetchOne(db, key: id) else { throw PersistenceError.notFound(id) }
            let existing = try MealTemplateItem
                .filter(MealTemplateItem.Columns.templateID == id && MealTemplateItem.Columns.deletedAt == nil)
                .fetchAll(db)
            for var old in existing {
                old.stampDeleted(now)
                try old.update(db)
            }
            try Self.insertItems(db, templateID: id, items: valid, now: now)
            template.stampUpdated(now)
            try template.update(db)
        }
    }

    public func softDelete(id: String) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var template = try MealTemplate.fetchOne(db, key: id), template.deletedAt == nil else { return }
            template.stampDeleted(now)
            try template.update(db)
        }
    }

    /// Undo for `softDelete`.
    public func restore(id: String) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var template = try MealTemplate.fetchOne(db, key: id), template.deletedAt != nil else { return }
            template.deletedAt = nil
            template.stampUpdated(now)
            try template.update(db)
        }
    }

    /// Logs `items` (the meal's items, possibly with changed amounts or some left out) into one slot and counts the
    /// use, all in one transaction. Returns the new entries.
    @discardableResult
    public func log(templateID: String, items: [DiaryRepository.LogItem], slotID: String, day: LocalDay) throws -> [DiaryEntry] {
        guard !items.isEmpty, items.allSatisfy({ $0.quantity.baseAmount > 0 }) else {
            throw PersistenceError.validation("Nothing to log.")
        }
        let now = clock.now()
        return try database.writer.write { db in
            guard var template = try MealTemplate.fetchOne(db, key: templateID) else { throw PersistenceError.notFound(templateID) }
            let entries = try items.map { item in
                try DiaryRepository.insertFoodEntry(
                    db, food: item.food, quantity: item.quantity, servingID: item.servingID, slotID: slotID, day: day, now: now,
                )
            }
            template.useCount += 1
            template.lastUsedAt = now
            template.stampUpdated(now)
            try template.update(db)
            return entries
        }
    }

    // MARK: Reads

    public func detail(id: String) throws -> MealTemplateDetail? {
        try database.reader.read { db in try Self.detail(db, id: id) }
    }

    /// Active meals, most used and most recently used first (`Frecency`), then by name.
    public func templates() throws -> [MealTemplateDetail] {
        let now = clock.now()
        return try database.reader.read { db in
            let templates = try MealTemplate.filter(MealTemplate.Columns.deletedAt == nil).fetchAll(db)
            return try templates.compactMap { try Self.detail(db, id: $0.id) }.sorted { lhs, rhs in
                let left = Frecency.score(useCount: lhs.template.useCount, lastUsedAt: lhs.template.lastUsedAt, now: now)
                let right = Frecency.score(useCount: rhs.template.useCount, lastUsedAt: rhs.template.lastUsedAt, now: now)
                if left != right {
                    return left > right
                }
                return lhs.template.name.localizedCaseInsensitiveCompare(rhs.template.name) == .orderedAscending
            }
        }
    }

    // MARK: Helpers

    static func create(_ db: Database, name: String, slotHint: String?, items: [NewItem], now: Date) throws -> MealTemplateDetail {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersistenceError.validation("A meal needs a name.") }
        let valid = items.filter { $0.grams > 0 && $0.grams.isFinite }
        guard !valid.isEmpty else { throw PersistenceError.validation("This meal has no foods to save.") }
        let template = MealTemplate(
            id: newID(), name: name, mealSlotHint: slotHint, useCount: 0, lastUsedAt: nil,
            createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
        )
        try template.insert(db)
        try insertItems(db, templateID: template.id, items: valid, now: now)
        guard let detail = try detail(db, id: template.id) else { throw PersistenceError.notFound(template.id) }
        return detail
    }

    static func insertItems(_ db: Database, templateID: String, items: [NewItem], now: Date) throws {
        for (index, item) in items.enumerated() {
            guard try Food.fetchOne(db, key: item.foodID) != nil else { throw PersistenceError.notFound(item.foodID) }
            try MealTemplateItem(
                id: newID(), templateID: templateID, foodID: item.foodID, grams: item.grams, servingID: item.servingID,
                sortOrder: index, createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            ).insert(db)
        }
    }

    static func detail(_ db: Database, id: String) throws -> MealTemplateDetail? {
        guard let template = try MealTemplate.fetchOne(db, key: id) else { return nil }
        let rows = try MealTemplateItem
            .filter(MealTemplateItem.Columns.templateID == id && MealTemplateItem.Columns.deletedAt == nil)
            .order(MealTemplateItem.Columns.sortOrder)
            .fetchAll(db)
        let items = try rows.compactMap { row -> MealTemplateDetail.Item? in
            guard let food = try Food.fetchOne(db, key: row.foodID) else { return nil }
            return MealTemplateDetail.Item(item: row, food: food)
        }
        return MealTemplateDetail(template: template, items: items)
    }
}
