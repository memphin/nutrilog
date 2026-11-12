import Core
import Foundation
import GRDB

/// A generic food from the read-only bundled USDA index (`Resources/FoodIndex/bundled_foods.sqlite`).
public struct BundledFood: Hashable, Sendable, Identifiable {
    public var id: String
    /// USDA FDC id.
    public var sourceID: String
    /// The name to show, in the food name language it was read in (Settings → Food names): ``croatianName`` for
    /// Croatian when the food has one, else ``englishName``.
    public var name: String
    /// The USDA description.
    public var englishName: String
    /// From `tools/food_names_hr.csv`; nil when the index has none for this food (older builds without `name_hr`).
    public var croatianName: String?
    public var per100: Nutrients

    /// `englishName` defaults to `name`.
    public init(
        id: String, sourceID: String, name: String, englishName: String? = nil, croatianName: String? = nil,
        per100: Nutrients,
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.englishName = englishName ?? name
        self.croatianName = croatianName
        self.per100 = per100
    }

    /// Every name the food goes by, the shown one first: search finds it by either, so matching a hit against the
    /// typed words has to look at both.
    public var names: [String] {
        var names = [name]
        for other in [englishName, croatianName].compactMap(\.self) where !names.contains(other) {
            names.append(other)
        }
        return names
    }
}

/// Read-only access to the bundled food index (backlog #5).
///
/// Names are read in the ``FoodNameLanguage`` each call is given — the app's resolved Settings → Food names — so a
/// change of the setting applies to the next search without reopening the index.
public final class BundledFoodIndex: Sendable {
    private let queue: DatabaseQueue
    /// The index has Croatian names; indexes built before them have no `name_hr` column and show English always.
    private let hasCroatian: Bool

    public init(url: URL) throws {
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: url.path, configuration: config)
        hasCroatian = try queue.read { db in try db.columns(in: "bundled_food").contains { $0.name == "name_hr" } }
    }

    /// The index shipped in the app bundle, if present.
    public static func inBundle(_ bundle: Bundle = .main) -> BundledFoodIndex? {
        let url = bundle.url(forResource: "bundled_foods", withExtension: "sqlite", subdirectory: "FoodIndex")
            ?? bundle.url(forResource: "bundled_foods", withExtension: "sqlite")
        return url.flatMap { try? BundledFoodIndex(url: $0) }
    }

    public func count() throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundled_food") ?? 0 }
    }

    /// The food with `id`, its ``BundledFood/name`` in `language`.
    public func food(id: String, language: FoodNameLanguage) throws -> BundledFood? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM bundled_food WHERE id = ?", arguments: [id])
                .map { food($0, language: language) }
        }
    }

    /// FDC id → both names of every food, for switching stored copies to another ``FoodNameLanguage``
    /// (`FoodRepository.applyBundledNames(_:from:)`). Indexes built without `name_hr` give English names only.
    public func bilingualNames() throws -> [String: BilingualFoodName] {
        let croatian = hasCroatian ? "name_hr" : "NULL AS name_hr"
        return try queue.read { db in
            var result: [String: BilingualFoodName] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT source_id, name, \(croatian) FROM bundled_food ORDER BY rowid") {
                let sourceID: String = row["source_id"]
                if result[sourceID] == nil { // one food per FDC id; should one repeat, the first row wins
                    result[sourceID] = BilingualFoodName(english: row["name"], croatian: row["name_hr"])
                }
            }
            return result
        }
    }

    /// FDC id → caffeine (mg per 100 g/ml) of every food with a known value; empty for indexes built without the
    /// `caffeine_mg_100` column.
    public func caffeineBySourceID() throws -> [String: Double] {
        try queue.read { db in
            guard try db.columns(in: "bundled_food").contains(where: { $0.name == "caffeine_mg_100" }) else { return [:] }
            var result: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: """
            SELECT source_id, caffeine_mg_100 FROM bundled_food WHERE caffeine_mg_100 IS NOT NULL
            """) {
                result[row["source_id"]] = row["caffeine_mg_100"]
            }
            return result
        }
    }

    /// FTS5 search over the English and the Croatian name, best match first (shorter shown name on a tie). Either
    /// name matches; names are shown in `language`.
    public func search(_ query: String, limit: Int, language: FoodNameLanguage) throws -> [BundledFood] {
        guard let pattern = FoodSearch.ftsPattern(query) else { return [] }
        let shownName = language == .croatian && hasCroatian ? "COALESCE(NULLIF(b.name_hr, ''), b.name)" : "b.name"
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT b.* FROM bundled_food_fts s JOIN bundled_food b ON b.rowid = s.rowid
            WHERE bundled_food_fts MATCH ? ORDER BY bm25(bundled_food_fts), length(\(shownName)) LIMIT ?
            """, arguments: [pattern, limit]).map { food($0, language: language) }
        }
    }

    private func food(_ row: Row, language: FoodNameLanguage) -> BundledFood {
        // `name_hr` is an optional column: indexes built without it read as nil. A blank name counts as none.
        let names = BilingualFoodName(english: row["name"], croatian: row["name_hr"])
        return BundledFood(
            id: row["id"], sourceID: row["source_id"],
            name: names.name(in: language),
            englishName: names.english, croatianName: names.croatian,
            per100: Nutrients(
                kcal: row["kcal_100"], proteinG: row["protein_g_100"], carbsG: row["carbs_g_100"], fatG: row["fat_g_100"],
                fiberG: row["fiber_g_100"], sugarG: row["sugar_g_100"], satFatG: row["sat_fat_g_100"], sodiumMg: row["sodium_mg_100"],
                // Optional column: indexes built without it read as nil.
                caffeineMg: row["caffeine_mg_100"],
            ),
        )
    }
}

/// One row of the unified search result list (FR-20).
public enum FoodSearchResult: Hashable, Sendable, Identifiable {
    case food(Food)
    case bundled(BundledFood)

    public var id: String {
        switch self {
        case let .food(food): "food:\(food.id)"
        case let .bundled(item): "bundled:\(item.id)"
        }
    }

    public var name: String {
        switch self {
        case let .food(food): food.name
        case let .bundled(item): item.name
        }
    }

    /// The names a hit can match on, ``name`` first: a bundled food also goes by its other-language name.
    public var names: [String] {
        switch self {
        case let .food(food): [food.name]
        case let .bundled(item): item.names
        }
    }

    public var brand: String? {
        if case let .food(food) = self {
            return food.brand
        }
        return nil
    }

    public var per100: Nutrients {
        switch self {
        case let .food(food): food.per100
        case let .bundled(item): item.per100
        }
    }

    /// Source badge (FR-20): custom, bundled (USDA), off, usda.
    public var source: FoodSource {
        switch self {
        case let .food(food): food.source
        case .bundled: .bundled
        }
    }
}

/// Unified local search over the user's foods (FTS5) and the bundled index (backlog #4, #5).
public struct FoodSearch: Sendable {
    let database: AppDatabase
    let bundled: BundledFoodIndex?
    /// The language bundled foods are shown in: Settings → Food names, resolved.
    let nameLanguage: FoodNameLanguage

    public init(_ database: AppDatabase, bundled: BundledFoodIndex?, nameLanguage: FoodNameLanguage) {
        self.database = database
        self.bundled = bundled
        self.nameLanguage = nameLanguage
    }

    /// User foods first — foods already logged before unused ones, then by FTS rank (bm25), use count and
    /// recency — followed by bundled foods that have no local copy yet (a copy merged into a still-active food counts as
    /// one). Prefix matching, case- and
    /// diacritic-insensitive ("cokolada" finds "Čokolada", "chick br" finds "Chicken breast").
    public func search(_ query: String, limit: Int = 50) throws -> [FoodSearchResult] {
        guard let pattern = Self.ftsPattern(query) else { return [] }
        let foods = try database.reader.read { db in
            try Food.fetchAll(db, sql: """
            SELECT f.* FROM food_fts s JOIN food f ON f.rowid = s.rowid
            WHERE food_fts MATCH ? AND f.deleted_at IS NULL
            ORDER BY (f.use_count > 0) DESC, bm25(food_fts), f.use_count DESC, f.last_used_at DESC
            LIMIT ?
            """, arguments: [pattern, limit])
        }
        var results = foods.map(FoodSearchResult.food)
        guard results.count < limit, let bundled else { return results }

        // The bundled index is built from USDA FDC with `source_id` = FDC id, the ids online USDA search returns, so a
        // food saved from either is the same as the bundled row.
        let copied = Set(foods.filter { $0.source == .bundled || $0.source == .usda }.compactMap(\.sourceID))
        // A copy merged into another food (Duplicate foods) counts as local while the kept food is active: the kept
        // food stands for it (shown above when it matches the query itself), so the bundled row doesn't come back.
        let alreadyLocal = try database.reader.read { db in
            var ids = try Set(String.fetchAll(db, sql: """
            SELECT source_id FROM food
            WHERE source IN ('bundled', 'usda') AND source_id IS NOT NULL AND deleted_at IS NULL
            """))
            let merged = try Food.fetchAll(db, sql: """
            SELECT * FROM food
            WHERE source IN ('bundled', 'usda') AND source_id IS NOT NULL AND deleted_at IS NOT NULL
              AND merged_into_id IS NOT NULL
            """)
            for food in merged {
                if let sourceID = food.sourceID, !ids.contains(sourceID), try FoodRepository.mergeKeeper(db, of: food) != nil {
                    ids.insert(sourceID)
                }
            }
            return ids
        }
        let hits = try bundled.search(query, limit: limit, language: nameLanguage)
        for item in hits where !copied.contains(item.sourceID) && !alreadyLocal.contains(item.sourceID) {
            results.append(.bundled(item))
            if results.count == limit {
                break
            }
        }
        return results
    }

    /// Builds an FTS5 query: every word becomes a quoted prefix term, all terms must match.
    /// Returns nil when the query has no searchable characters.
    static func ftsPattern(_ query: String) -> String? {
        let words = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let variants = words.map(dVariants)
        guard variants.contains(where: { $0.count > 1 }) else {
            return words.map { "\"\($0)\"*" }.joined(separator: " ")
        }
        return variants.map { alternatives in
            alternatives.count == 1
                ? "\"\(alternatives[0])\"*"
                : "(" + alternatives.map { "\"\($0)\"*" }.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    /// The tokenizer's `remove_diacritics` folds "č" to "c" but keeps "đ" (it has no decomposition), so "smeda" or
    /// "govedja" would miss "smeđa" / "goveđa". Each "dj" or "d" in a typed word may stand for "đ": the word itself
    /// first, then those spellings (the first three d's only, so a word gives at most 8).
    static func dVariants(_ word: String) -> [String] {
        let chars = Array(word.lowercased())
        // Where a "đ" may be meant: (start, length) of each "dj" or "d".
        var slots: [(start: Int, length: Int)] = []
        var i = 0
        while i < chars.count, slots.count < 3 {
            if chars[i] == "d" {
                let length = i + 1 < chars.count && chars[i + 1] == "j" ? 2 : 1
                slots.append((i, length))
                i += length
            } else {
                i += 1
            }
        }
        guard !slots.isEmpty else { return [word] }
        var variants = [word]
        for mask in 1 ..< (1 << slots.count) {
            var variant = chars
            for (bit, slot) in slots.enumerated().reversed() where mask & (1 << bit) != 0 {
                variant.replaceSubrange(slot.start ..< slot.start + slot.length, with: ["đ"])
            }
            variants.append(String(variant))
        }
        return variants
    }
}
