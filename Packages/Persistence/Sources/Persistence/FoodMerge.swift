import Core
import Foundation
import GRDB

/// Duplicate foods: find likely duplicates and merge them (FR-26, backlog #41).
public extension FoodRepository {
    /// Groups of active foods that are probably the same: they share a barcode (an Open Food Facts copy's source id
    /// counts as one) or the same normalized name + brand. Groups are ordered by the name
    /// of their suggested keeper. In each group the suggested
    /// keeper comes first: complete data, then your own foods, then the most used, then the oldest.
    func duplicateGroups() throws -> [[FoodDetail]] {
        try database.reader.read { db in
            let foods = try Food
                .filter(Food.Columns.deletedAt == nil)
                .order(Food.Columns.createdAt, Food.Columns.id)
                .fetchAll(db)
            var details: [String: FoodDetail] = [:]
            var candidates: [FoodDuplicates.Candidate] = []
            for food in foods {
                guard let detail = try Self.detail(db, id: food.id) else { continue }
                details[food.id] = detail
                var barcodes = detail.barcodes
                if food.source == .off, let code = food.sourceID.flatMap({ Barcode.normalize($0) }), !barcodes.contains(code) {
                    barcodes.append(code)
                }
                candidates.append(FoodDuplicates.Candidate(id: food.id, name: food.name, brand: food.brand, barcodes: barcodes))
            }
            // Groups by the name of their suggested keeper, so the list is stable from one visit to the next.
            return FoodDuplicates.groups(candidates)
                .map { ids in ids.compactMap { details[$0] }.sorted(by: Self.isBetterKeeper) }
                .sorted { lhs, rhs in
                    let left = lhs.first?.food.name ?? "", right = rhs.first?.food.name ?? ""
                    let order = left.localizedCaseInsensitiveCompare(right)
                    return order != .orderedSame ? order == .orderedAscending : (lhs.first?.food.id ?? "") < (rhs.first?.food.id ?? "")
                }
        }
    }

    /// Merges `removeIDs` into `keepID` in one transaction:
    ///
    /// - diary entries and saved-meal items of the removed foods point to the kept food (diary snapshots are
    ///   untouched, so history doesn't change); so do rows of the legacy `recipe_ingredient` table;
    /// - barcodes move over; servings the kept food lacks (by label) are copied;
    /// - missing details of the kept food (brand, local name, image, Nutri-Score, optional nutrients) are filled in
    ///   from the removed ones; use counts add up, the latest use and a favorite mark are kept, and so is a
    ///   "Counts as a drink" choice when the kept food has none;
    /// - the removed foods are soft-deleted and remember the kept food (`Food.mergedIntoID`), so a copy of a bundled or
    ///   USDA food that was merged away resolves to the kept food in search, ``localCopy(of:)`` and ``saveCopy(_:)``
    ///   instead of coming back.
    @discardableResult
    func merge(keep keepID: String, remove removeIDs: [String]) throws -> FoodDetail {
        let ids = removeIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        guard !ids.isEmpty, !ids.contains(keepID) else {
            throw PersistenceError.validation("choose one food to keep and at least one other to merge into it")
        }
        let now = clock.now()
        return try database.writer.write { db in
            guard var keep = try Food.fetchOne(db, key: keepID), keep.deletedAt == nil else { throw PersistenceError.notFound(keepID) }
            var labels = try Set(
                Serving.filter(Serving.Columns.foodID == keepID && Serving.Columns.deletedAt == nil).fetchAll(db).map(\.label),
            )
            var nextSort = try (Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM serving WHERE food_id = ?", arguments: [keepID]) ?? -1) +
                1
            let stamp = Timestamp.string(now)
            for id in ids {
                guard var removed = try Food.fetchOne(db, key: id), removed.deletedAt == nil else { throw PersistenceError.notFound(id) }
                for table in ["diary_entry", "planned_entry", "recipe_ingredient"] {
                    try db.execute(
                        sql: "UPDATE \(table) SET food_id = ?, updated_at = ?, revision = revision + 1 WHERE food_id = ?",
                        arguments: [keepID, stamp, id],
                    )
                }
                // The removed food's servings don't exist on the kept food: the items keep their amount in g/ml.
                try db.execute(
                    sql: """
                    UPDATE meal_template_item SET food_id = ?, serving_id = NULL, updated_at = ?, revision = revision + 1
                    WHERE food_id = ?
                    """,
                    arguments: [keepID, stamp, id],
                )
                try db.execute(sql: "UPDATE food_barcode SET food_id = ? WHERE food_id = ?", arguments: [keepID, id])
                for serving in try Serving
                    .filter(Serving.Columns.foodID == id && Serving.Columns.deletedAt == nil)
                    .order(Serving.Columns.sortOrder)
                    .fetchAll(db) where !labels.contains(serving.label) && removed.isLiquid == keep.isLiquid && !removed.perServingOnly
                {
                    var copy = Serving(foodID: keepID, label: serving.label, grams: serving.grams, sortOrder: nextSort)
                    copy.stampCreated(now)
                    try copy.insert(db)
                    labels.insert(serving.label)
                    nextSort += 1
                }

                keep.brand = keep.brand.nonEmpty ?? removed.brand.nonEmpty
                keep.nameLocal = keep.nameLocal.nonEmpty ?? removed.nameLocal.nonEmpty
                keep.imageURL = keep.imageURL.nonEmpty ?? removed.imageURL.nonEmpty
                keep.nutriscore = keep.nutriscore.nonEmpty ?? removed.nutriscore.nonEmpty
                keep.notes = keep.notes.nonEmpty ?? removed.notes.nonEmpty
                // Optional nutrients only when both describe the same thing per 100 g/ml.
                if removed.isLiquid == keep.isLiquid, !removed.perServingOnly, !keep.perServingOnly {
                    keep.fiberG100 = keep.fiberG100 ?? removed.fiberG100
                    keep.sugarG100 = keep.sugarG100 ?? removed.sugarG100
                    keep.satFatG100 = keep.satFatG100 ?? removed.satFatG100
                    keep.sodiumMg100 = keep.sodiumMg100 ?? removed.sodiumMg100
                    keep.caffeineMg100 = keep.caffeineMg100 ?? removed.caffeineMg100
                }
                keep.useCount += removed.useCount
                keep.lastUsedAt = [keep.lastUsedAt, removed.lastUsedAt].compactMap(\.self).max()
                keep.isFavorite = keep.isFavorite || removed.isFavorite
                keep.countsAsFluid = keep.countsAsFluid ?? removed.countsAsFluid // "Counts as a drink", unless set here

                removed.mergedIntoID = keepID
                removed.stampDeleted(now)
                try removed.update(db)
            }
            keep.mergedIntoID = nil // active, so it isn't merged into anything (and no chain can loop back through it)
            keep.stampUpdated(now)
            try keep.update(db)
            guard let detail = try Self.detail(db, id: keepID) else { throw PersistenceError.notFound(keepID) }
            return detail
        }
    }

    /// The active food `food` was finally merged into: follows `merged_into_id` through later merges of the kept
    /// food. nil when `food` wasn't merged away, or the chain ends at a food the user deleted (or loops).
    static func mergeKeeper(_ db: Database, of food: Food) throws -> Food? {
        var visited: Set<String> = [food.id]
        var next = food.mergedIntoID
        while let id = next, visited.insert(id).inserted {
            guard let target = try Food.fetchOne(db, key: id) else { return nil }
            if target.deletedAt == nil {
                return target
            }
            next = target.mergedIntoID
        }
        return nil
    }

    /// The active food a deleted copy with `sourceID` from one of `sources` was merged into, if any (oldest copy first).
    static func mergeKeeper(_ db: Database, sources: [FoodSource], sourceID: String) throws -> Food? {
        let merged = try Food
            .filter(sources.contains(Food.Columns.source) && Food.Columns.sourceID == sourceID)
            .filter(Food.Columns.deletedAt != nil && Food.Columns.mergedIntoID != nil)
            .order(Food.Columns.createdAt, Food.Columns.id)
            .fetchAll(db)
        for food in merged {
            if let keeper = try mergeKeeper(db, of: food) {
                return keeper
            }
        }
        return nil
    }

    private static func isBetterKeeper(_ lhs: FoodDetail, _ rhs: FoodDetail) -> Bool {
        func rank(_ detail: FoodDetail) -> (Int, Int, Int) {
            (
                detail.food.dataQuality == .complete && !detail.food.perServingOnly ? 0 : 1,
                detail.food.source == .custom ? 0 : 1,
                -detail.food.useCount,
            )
        }
        let left = rank(lhs), right = rank(rhs)
        if left != right {
            return left < right
        }
        return (lhs.food.createdAt, lhs.food.id) < (rhs.food.createdAt, rhs.food.id)
    }
}

private extension String? {
    /// nil for nil or blank text.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
