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
    /// Servings missing from `detail.servings` are soft-deleted; barcodes are replaced: codes no longer in
    /// `detail.barcodes` are unlinked, so a scan of them no longer finds this food.
    ///
    /// A barcode carried by another *active* food fails with ``PersistenceError/barcodeInUse(barcode:foodID:)``
    /// unless the user agreed to move it: `movingBarcodes` maps each stored code (``BarcodeOwner/storedBarcode``) to
    /// the id of the food it is taken from. It is then unlinked from that food, which gets a new `updated_at`; if
    /// the code belongs to a different active food by now, the save fails with `barcodeInUse` instead. Codes of
    /// deleted foods are always taken over.
    @discardableResult
    public func save(_ detail: FoodDetail, movingBarcodes: [String: String] = [:]) throws -> FoodDetail {
        let now = clock.now()
        // The food editor's values: per-100 nutrients and serving weights (copies of online foods aren't checked).
        try EntryLimits.validate(detail.food.per100)
        for serving in detail.servings {
            try EntryLimits.validate(amount: serving.grams)
        }
        let barcodes = try normalizedBarcodes(detail.barcodes)
        return try database.writer.write { db in
            try Self.save(db, detail: detail, barcodes: barcodes, now: now, movingBarcodes: movingBarcodes)
        }
    }

    /// Saves `converted`, a per-serving placeholder (`Food.perServingOnly`: values of one serving stored as per 100,
    /// with a stand-in default serving of 100 g/ml) converted to real per-100 values once its serving weight is known
    /// (FoodLookup's `convertingPerServingPlaceholder(servingWeight:missing:)`), like ``save(_:movingBarcodes:)``.
    ///
    /// While the food was a placeholder, every amount stored for it meant servings × the stand-in weight, not real
    /// g/ml. In the same transaction, when the *stored* food is still a placeholder and `converted` no longer is, those
    /// amounts are rescaled by `new default serving weight / stand-in weight`, so "1 serving" stays one serving:
    /// `grams` of its diary entries, planned entries and saved-meal items (soft-deleted ones too, so an undo can't bring
    /// back a stale amount; each gets a new `updated_at` / `revision`) and its last quantity when that is a base amount.
    /// Nutrient snapshots are unchanged and no Apple Health write is queued. When the stored food is no longer a
    /// placeholder (already converted), nothing is rescaled: this is a plain save.
    @discardableResult
    public func saveConvertedPlaceholder(_ converted: FoodDetail, movingBarcodes: [String: String] = [:]) throws -> FoodDetail {
        let now = clock.now()
        try EntryLimits.validate(converted.food.per100)
        for serving in converted.servings {
            try EntryLimits.validate(amount: serving.grams)
        }
        let barcodes = try normalizedBarcodes(converted.barcodes)
        return try database.writer.write { db in
            var detail = converted
            if let stored = try Food.fetchOne(db, key: converted.food.id), stored.perServingOnly, !converted.food.perServingOnly,
               let factor = try Self.placeholderRescaleFactor(db, stored: stored, converted: converted)
            {
                try Self.rescaleAmounts(db, foodID: stored.id, by: factor, now: now)
                // The remembered quantity is the stored one (logging updates it), rescaled when it is a base amount.
                detail.food.lastServingID = stored.lastServingID
                detail.food.lastAmount = stored.lastServingID == nil ? stored.lastAmount.map { $0 * factor } : stored.lastAmount
            }
            return try Self.save(db, detail: detail, barcodes: barcodes, now: now, movingBarcodes: movingBarcodes)
        }
    }

    /// `new default serving weight / stand-in weight` for converting `stored` (a placeholder) into `converted`, or nil
    /// when either weight is unknown or the factor is 1.
    private static func placeholderRescaleFactor(_ db: Database, stored: Food, converted: FoodDetail) throws -> Double? {
        guard let defaultID = stored.defaultServingID,
              let standIn = try Serving.fetchOne(db, key: defaultID), standIn.grams > 0,
              let newServing = converted.servings.first(where: { $0.id == defaultID }), newServing.grams > 0
        else { return nil }
        let factor = newServing.grams / standIn.grams
        return factor.isFinite && factor > 0 && factor != 1 ? factor : nil
    }

    /// Multiplies the amounts stored for `foodID` (diary entries, planned entries, saved-meal items, active or not)
    /// by `factor`; nutrient snapshots stay as they are. A diary entry's fluid snapshot is its amount in ml, so it is
    /// scaled too (NULL stays NULL). Deliberately not capped at ``EntryLimits/maxAmount``: grams must stay consistent
    /// with the nutrient snapshot, and later edits validate only the new amount.
    private static func rescaleAmounts(_ db: Database, foodID: String, by factor: Double, now: Date) throws {
        let stamp = Timestamp.string(now)
        for table in ["diary_entry", "planned_entry", "meal_template_item"] {
            let fluid = table == "diary_entry" ? ", fluid_ml = fluid_ml * ?1" : ""
            try db.execute(
                sql: """
                UPDATE \(table) SET grams = grams * ?1\(fluid), updated_at = ?2, revision = revision + 1
                WHERE food_id = ?3 AND grams > 0
                """,
                arguments: [factor, stamp, foodID],
            )
        }
    }

    /// Body of ``save(_:movingBarcodes:)`` inside a write transaction; `barcodes` are already normalized and
    /// deduplicated.
    static func save(
        _ db: Database,
        detail: FoodDetail,
        barcodes: [String],
        now: Date,
        movingBarcodes: [String: String] = [:],
    ) throws -> FoodDetail {
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

        // Barcodes the user agreed to move here: only from the food they were told about. A code that changed owner
        // since (or is stored under another reading of the same digits) fails instead of being taken silently.
        for (code, expectedOwner) in movingBarcodes.sorted(by: { $0.key < $1.key }) {
            guard let link = try FoodBarcode.fetchOne(db, key: code), link.foodID != food.id else { continue }
            let ownerFood = try Food.fetchOne(db, key: link.foodID)
            if ownerFood?.deletedAt == nil, link.foodID != expectedOwner {
                throw PersistenceError.barcodeInUse(barcode: code, foodID: link.foodID)
            }
            try Self.takeOver(link, from: ownerFood, db: db, now: now)
        }
        for code in barcodes {
            if let owner = try FoodBarcode.fetchOne(db, key: code), owner.foodID != food.id {
                let ownerFood = try Food.fetchOne(db, key: owner.foodID)
                if ownerFood?.deletedAt == nil {
                    throw PersistenceError.barcodeInUse(barcode: code, foodID: owner.foodID)
                }
                try Self.takeOver(owner, from: ownerFood, db: db, now: now) // previous owner was deleted
            }
        }
        try FoodBarcode.filter(FoodBarcode.Columns.foodID == food.id).deleteAll(db)
        for code in barcodes {
            try FoodBarcode(barcode: code, foodID: food.id, createdAt: now).insert(db)
        }
        return FoodDetail(food: food, servings: kept, barcodes: barcodes)
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
        // scanner reports UPC-E (or vice versa). Try every reading, the hinted one first (`Barcode.candidates`).
        try food(barcodes: Barcode.candidates(raw, symbology: symbology))
    }

    /// Active (non-deleted) food carrying the first of `candidates` that any food carries. `candidates` are
    /// normalized keys, most likely first, e.g. `Barcode.candidates(_:symbology:)` or the scanner's candidates.
    public func food(barcodes candidates: [String]) throws -> FoodDetail? {
        guard !candidates.isEmpty else { return nil }
        return try database.reader.read { db in try Self.activeFood(db, barcodes: candidates) }
    }

    /// Other active foods carrying one of `barcodes` (normalized keys) in any reading of its digits
    /// (`Barcode.candidates`: an 8-digit code stored as UPC-E on one food and as EAN-8 on another is the same
    /// product to the scanner), in the order of `barcodes`. Lets the editor ask "This barcode is on 'X' — move it
    /// here?" before saving instead of failing; pass each owner's `storedBarcode` → `food.id` to
    /// ``save(_:movingBarcodes:)``.
    public func activeOwners(of barcodes: [String], excluding foodID: String?) throws -> [BarcodeOwner] {
        guard !barcodes.isEmpty else { return [] }
        return try database.reader.read { db in
            var result: [BarcodeOwner] = []
            for code in barcodes {
                var keys = [code]
                for candidate in Barcode.candidates(code) where !keys.contains(candidate) {
                    keys.append(candidate)
                }
                for key in keys where !result.contains(where: { $0.storedBarcode == key }) {
                    guard let link = try FoodBarcode.fetchOne(db, key: key), link.foodID != foodID,
                          let food = try Food.fetchOne(db, key: link.foodID), food.deletedAt == nil
                    else { continue }
                    result.append(BarcodeOwner(barcode: code, storedBarcode: key, food: food))
                }
            }
            return result
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

    /// All active custom foods (including any legacy recipe food, see `FoodSource.recipe`), by name.
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
    /// The copy keeps `source_id` = FDC id so it is never duplicated. An active food saved from online USDA search
    /// with the same FDC id is the same food and is reused instead. When the copy (bundled or USDA) was merged into
    /// another food that is still active, that kept food is returned; a deleted copy is revived otherwise.
    /// A new copy takes the shown name (`BundledFood.name`, in the app language at that moment) and keeps it; the
    /// other language's name goes to `nameLocal`, which search also matches, so "losos" and "salmon" both still find
    /// the food after it was logged.
    public func localCopy(of bundled: BundledFood) throws -> Food {
        let now = clock.now()
        return try database.writer.write { db in
            let existing = try Food
                .filter(Food.Columns.source == FoodSource.bundled && Food.Columns.sourceID == bundled.sourceID)
                .order(Food.Columns.deletedAt != nil, Food.Columns.createdAt)
                .fetchOne(db)
            if existing == nil || existing?.deletedAt != nil {
                if let usda = try Self.activeFood(db, source: .usda, sourceID: bundled.sourceID) {
                    return usda // no active bundled copy, but the USDA one is the same food
                }
                // A copy merged into another food (Duplicate foods) stays merged: the kept food is this food now.
                if let keeper = try Self.mergeKeeper(db, sources: [.bundled, .usda], sourceID: bundled.sourceID) {
                    return keeper
                }
            }
            if let existing {
                if existing.deletedAt != nil {
                    var revived = existing
                    revived.deletedAt = nil
                    revived.mergedIntoID = nil // the food it was merged into is gone too
                    revived.stampUpdated(now)
                    try revived.update(db)
                    return revived
                }
                return existing
            }
            var food = Food(name: bundled.name, source: .bundled, sourceID: bundled.sourceID, per100: bundled.per100)
            food.nameLocal = bundled.names.dropFirst().first
            food.stampCreated(now)
            try food.insert(db)
            return food
        }
    }

    // MARK: Copies of online foods

    /// Saves a copy of a food from an online source (Open Food Facts, USDA) unless one is already stored, in one
    /// transaction so repeated or concurrent calls never create duplicates. Idempotent:
    ///
    /// 1. An active food already carrying one of `detail.barcodes` is returned as is (the user's own food for a
    ///    code wins).
    /// 2. Otherwise a food with the same `source` + `sourceID` is reused: returned as is when active (with
    ///    `detail.barcodes` linked to it, taking them over from deleted foods), or revived with `detail`'s values when deleted.
    /// 3. Otherwise `detail` is inserted.
    ///
    /// Barcodes that aren't valid retail codes are dropped rather than failing the save.
    @discardableResult
    public func saveCopy(_ detail: FoodDetail) throws -> FoodDetail {
        let now = clock.now()
        let barcodes = detail.barcodes.compactMap { Barcode.normalize($0) }.reduce(into: [String]()) { result, code in
            if !result.contains(code) {
                result.append(code)
            }
        }
        return try database.writer.write { db in
            if let owner = try Self.activeFood(db, barcodes: barcodes) {
                return owner
            }
            if let sourceID = detail.food.sourceID, detail.food.source != .custom,
               let existing = try Self.existingCopy(db, source: detail.food.source, sourceID: sourceID),
               let existingDetail = try Self.detail(db, id: existing.id)
            {
                if existing.deletedAt == nil {
                    guard !barcodes.isEmpty else { return existingDetail }
                    for code in barcodes {
                        // An active owner was returned above, so only a deleted food can still hold the code.
                        if let owner = try FoodBarcode.fetchOne(db, key: code) {
                            try Self.takeOver(owner, from: Food.fetchOne(db, key: owner.foodID), db: db, now: now)
                        }
                        try FoodBarcode(barcode: code, foodID: existing.id, createdAt: now).insert(db)
                    }
                    var linked = existing
                    linked.stampUpdated(now) // its barcodes changed
                    try linked.update(db)
                    return try Self.detail(db, id: existing.id) ?? existingDetail
                }
                var revived = detail
                revived.food.id = existing.id
                revived.food.isFavorite = existing.isFavorite
                revived.food.countsAsFluid = existing.countsAsFluid ?? revived.food.countsAsFluid // the user's choice
                revived.food.deletedAt = nil
                revived.food.mergedIntoID = nil
                revived.servings = Self.reusingServingIDs(detail.servings, from: existingDetail.servings)
                // Keep the remembered quantity only while it still means something: a base amount, or a serving
                // that the revived food still has.
                if existing.lastServingID == nil || revived.servings.contains(where: { $0.id == existing.lastServingID }) {
                    revived.food.lastServingID = existing.lastServingID
                    revived.food.lastAmount = existing.lastAmount
                }
                if let defaultID = detail.food.defaultServingID,
                   let index = detail.servings.firstIndex(where: { $0.id == defaultID })
                {
                    revived.food.defaultServingID = revived.servings[index].id
                }
                return try Self.save(db, detail: revived, barcodes: barcodes, now: now)
            }
            return try Self.save(db, detail: detail, barcodes: barcodes, now: now)
        }
    }

    /// The stored copy `saveCopy` reuses for `source` + `sourceID`: an active one of the same source; else, for a USDA
    /// food, an active local copy of the bundled index (built from the same FDC ids), so the food isn't stored twice;
    /// else the active food a copy was merged into (``merge(keep:remove:)``); else a deleted one of the same source
    /// (revived, with its stale `merged_into_id` cleared).
    private static func existingCopy(_ db: Database, source: FoodSource, sourceID: String) throws -> Food? {
        let sameSource = try Food
            .filter(Food.Columns.source == source && Food.Columns.sourceID == sourceID)
            .order(Food.Columns.deletedAt != nil, Food.Columns.createdAt)
            .fetchOne(db)
        if let sameSource, sameSource.deletedAt == nil {
            return sameSource
        }
        if source == .usda, let bundled = try activeFood(db, source: .bundled, sourceID: sourceID) {
            return bundled
        }
        // A copy merged into another food (Duplicate foods) resolves to the kept food instead of coming back.
        if let keeper = try mergeKeeper(db, sources: source == .usda ? [.usda, .bundled] : [source], sourceID: sourceID) {
            return keeper
        }
        return sameSource
    }

    /// The oldest active food with `source` + `sourceID`.
    static func activeFood(_ db: Database, source: FoodSource, sourceID: String) throws -> Food? {
        try Food
            .filter(Food.Columns.source == source && Food.Columns.sourceID == sourceID && Food.Columns.deletedAt == nil)
            .order(Food.Columns.createdAt)
            .fetchOne(db)
    }

    /// `servings` with the IDs of same-label servings in `existing`, so a revived food keeps its serving rows.
    private static func reusingServingIDs(_ servings: [Serving], from existing: [Serving]) -> [Serving] {
        var unused = existing
        return servings.map { serving in
            guard let index = unused.firstIndex(where: { $0.label == serving.label }) else { return serving }
            var reused = serving
            reused.id = unused.remove(at: index).id
            return reused
        }
    }

    // MARK: Helpers

    /// Removes `link` from its deleted owner so another food can take the barcode; the owner's barcodes changed, so
    /// it gets a new `updated_at` / `revision`.
    private static func takeOver(_ link: FoodBarcode, from owner: Food?, db: Database, now: Date) throws {
        try link.delete(db)
        if var owner {
            owner.stampUpdated(now)
            try owner.update(db)
        }
    }

    /// First active food carrying one of the normalized `barcodes`, tried in order.
    static func activeFood(_ db: Database, barcodes: [String]) throws -> FoodDetail? {
        for code in barcodes {
            if let link = try FoodBarcode.fetchOne(db, key: code), let detail = try detail(db, id: link.foodID),
               detail.food.deletedAt == nil
            {
                return detail
            }
        }
        return nil
    }

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
