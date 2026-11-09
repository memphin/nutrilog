import Core
import Foundation
import GRDB

/// Create / update / soft-delete foods with their servings and barcodes; lookups for
/// favorites, recents and barcodes (backlog #2, #8).
public struct FoodRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Writes

    /// Inserts a new food (or updates it when `detail.food.id` already exists) with its servings and barcodes.
    /// Servings missing from `detail.servings` are soft-deleted; barcodes are replaced.
    @discardableResult
    public func save(_ detail: FoodDetail) throws -> FoodDetail {
        let now = clock.now()
        let barcodes = try normalizedBarcodes(detail.barcodes)
        return try database.writer.write { db in
            var food = detail.food
            if let existing = try Food.fetchOne(db, key: food.id) {
                food.createdAt = existing.createdAt
                food.revision = existing.revision
                food.useCount = existing.useCount
                food.lastUsedAt = existing.lastUsedAt
                food.stampUpdated(now)
                try food.update(db)
            } else {
                food.stampCreated(now)
                try food.insert(db)
            }

            // Servings
            let existingServings = try Serving.filter(Serving.Columns.foodID == food.id).fetchAll(db)
            var kept: [Serving] = []
            for (index, var serving) in detail.servings.enumerated() {
                serving.foodID = food.id
                serving.sortOrder = index
                if let old = existingServings.first(where: { $0.id == serving.id }) {
                    serving.createdAt = old.createdAt
                    serving.revision = old.revision
                    if old.label != serving.label || old.grams != serving.grams || old.sortOrder != index || old.deletedAt != nil {
                        serving.deletedAt = nil
                        serving.stampUpdated(now)
                    } else {
                        serving.updatedAt = old.updatedAt
                    }
                    try serving.update(db)
                } else {
                    serving.stampCreated(now)
                    try serving.insert(db)
                }
                kept.append(serving)
            }
            for var old in existingServings where old.deletedAt == nil && !kept.contains(where: { $0.id == old.id }) {
                old.stampDeleted(now)
                try old.update(db)
            }
            if let defaultID = food.defaultServingID, !kept.contains(where: { $0.id == defaultID }) {
                food.defaultServingID = nil
                try food.update(db)
            }

            // Barcodes
            for code in barcodes {
                if let owner = try FoodBarcode.fetchOne(db, key: code), owner.foodID != food.id {
                    let ownerFood = try Food.fetchOne(db, key: owner.foodID)
                    if ownerFood?.deletedAt == nil {
                        throw PersistenceError.barcodeInUse(barcode: code, foodID: owner.foodID)
                    }
                    try owner.delete(db) // previous owner was deleted: take the barcode over
                }
            }
            try FoodBarcode.filter(FoodBarcode.Columns.foodID == food.id).deleteAll(db)
            for code in barcodes {
                try FoodBarcode(barcode: code, foodID: food.id, createdAt: now).insert(db)
            }
            return FoodDetail(food: food, servings: kept, barcodes: barcodes)
        }
    }

    /// Soft delete: sets `deleted_at`, bumps `revision`. Diary history is unaffected (entries keep snapshots).
    public func softDelete(id: String) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var food = try Food.fetchOne(db, key: id) else { throw PersistenceError.notFound(id) }
            guard food.deletedAt == nil else { return }
            food.stampDeleted(now)
            try food.update(db)
        }
    }

    public func setFavorite(id: String, _ isFavorite: Bool) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var food = try Food.fetchOne(db, key: id) else { throw PersistenceError.notFound(id) }
            guard food.isFavorite != isFavorite else { return }
            food.isFavorite = isFavorite
            food.stampUpdated(now)
            try food.update(db)
        }
    }

    // MARK: Reads

    public func food(id: String) throws -> Food? {
        try database.reader.read { db in try Food.fetchOne(db, key: id) }
    }

    public func detail(id: String) throws -> FoodDetail? {
        try database.reader.read { db in try Self.detail(db, id: id) }
    }

    /// Active (non-deleted) food carrying `barcode`; the input is normalized first.
    public func food(barcode raw: String, symbology: Barcode.Symbology = .unknown) throws -> FoodDetail? {
        // Saved codes are normalized without a symbology hint, so an 8-digit code may be stored as EAN-8 while the
        // scanner reports UPC-E (or vice versa). Try every reading, the hinted one first.
        var candidates: [String] = []
        for hint in [symbology, .unknown, .upcE] {
            if let code = Barcode.normalize(raw, symbology: hint), !candidates.contains(code) {
                candidates.append(code)
            }
        }
        guard !candidates.isEmpty else { return nil }
        return try database.reader.read { db in
            for code in candidates {
                if let link = try FoodBarcode.fetchOne(db, key: code), let detail = try Self.detail(db, id: link.foodID),
                   detail.food.deletedAt == nil
                {
                    return detail
                }
            }
            return nil
        }
    }

    public func favorites() throws -> [Food] {
        try database.reader.read { db in
            try Food
                .filter(Food.Columns.isFavorite == true && Food.Columns.deletedAt == nil)
                .order(Food.Columns.name.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    /// Recently logged foods, ranked so foods usually eaten in `slotID` come first (backlog #8).
    /// Considers the last `days` days of diary entries; returns at most `limit` foods.
    public func recents(slotID: String?, limit: Int = 50, days: Int = 60) throws -> [Food] {
        let now = clock.now()
        let since = Timestamp.string(now.addingTimeInterval(-Double(days) * 86400))
        return try database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT e.food_id AS food_id,
                   SUM(CASE WHEN e.meal_slot_id = ? THEN 1 ELSE 0 END) AS in_slot,
                   COUNT(*) AS total,
                   MAX(e.logged_at) AS last_used
            FROM diary_entry e
            JOIN food f ON f.id = e.food_id AND f.deleted_at IS NULL
            WHERE e.deleted_at IS NULL AND e.food_id IS NOT NULL AND e.logged_at >= ?
            GROUP BY e.food_id
            """, arguments: [slotID ?? "", since])
            let usages = rows.compactMap { row -> RecentsRanking.Usage? in
                guard let id: String = row["food_id"], let last: String = row["last_used"],
                      let lastDate = Timestamp.date(last) else { return nil }
                return RecentsRanking.Usage(foodID: id, countInSlot: row["in_slot"], countTotal: row["total"], lastUsed: lastDate)
            }
            let ids = Array(RecentsRanking.rank(usages, now: now).prefix(limit))
            let foods = try Food.fetchAll(db, keys: ids)
            let byID = Dictionary(uniqueKeysWithValues: foods.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    /// All active custom foods and recipes, by name.
    public func customFoods() throws -> [Food] {
        try database.reader.read { db in
            try Food
                .filter(Food.Columns.deletedAt == nil && [FoodSource.custom, .recipe].contains(Food.Columns.source))
                .order(Food.Columns.name.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    // MARK: Bundled foods

    /// Returns the local copy of a bundled food, creating it on first use (backlog #5).
    /// The copy keeps `source_id` = FDC id so it is never duplicated.
    public func localCopy(of bundled: BundledFood) throws -> Food {
        let now = clock.now()
        return try database.writer.write { db in
            if let existing = try Food
                .filter(Food.Columns.source == FoodSource.bundled && Food.Columns.sourceID == bundled.sourceID)
                .fetchOne(db)
            {
                if existing.deletedAt != nil {
                    var revived = existing
                    revived.deletedAt = nil
                    revived.stampUpdated(now)
                    try revived.update(db)
                    return revived
                }
                return existing
            }
            var food = Food(name: bundled.name, source: .bundled, sourceID: bundled.sourceID, per100: bundled.per100)
            food.stampCreated(now)
            try food.insert(db)
            return food
        }
    }

    // MARK: Helpers

    static func detail(_ db: Database, id: String) throws -> FoodDetail? {
        guard let food = try Food.fetchOne(db, key: id) else { return nil }
        let servings = try Serving
            .filter(Serving.Columns.foodID == id && Serving.Columns.deletedAt == nil)
            .order(Serving.Columns.sortOrder)
            .fetchAll(db)
        let barcodes = try String.fetchAll(
            db, sql: "SELECT barcode FROM food_barcode WHERE food_id = ? ORDER BY barcode", arguments: [id],
        )
        return FoodDetail(food: food, servings: servings, barcodes: barcodes)
    }

    private func normalizedBarcodes(_ raw: [String]) throws -> [String] {
        var result: [String] = []
        for code in raw where !code.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let normalized = Barcode.normalize(code) else { throw PersistenceError.invalidBarcode(code) }
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }
}
