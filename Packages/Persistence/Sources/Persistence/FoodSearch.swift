import Core
import Foundation
import GRDB

/// A generic food from the read-only bundled USDA index (`Resources/FoodIndex/bundled_foods.sqlite`).
public struct BundledFood: Hashable, Sendable, Identifiable {
    public var id: String
    /// USDA FDC id.
    public var sourceID: String
    public var name: String
    public var per100: Nutrients
}

/// Read-only access to the bundled food index (backlog #5).
public final class BundledFoodIndex: Sendable {
    private let queue: DatabaseQueue

    public init(url: URL) throws {
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: url.path, configuration: config)
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

    public func food(id: String) throws -> BundledFood? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM bundled_food WHERE id = ?", arguments: [id]).map(Self.food)
        }
    }

    /// FTS5 search, best match first.
    public func search(_ query: String, limit: Int) throws -> [BundledFood] {
        guard let pattern = FoodSearch.ftsPattern(query) else { return [] }
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT b.* FROM bundled_food_fts s JOIN bundled_food b ON b.rowid = s.rowid
            WHERE bundled_food_fts MATCH ? ORDER BY bm25(bundled_food_fts), length(b.name) LIMIT ?
            """, arguments: [pattern, limit]).map(Self.food)
        }
    }

    private static func food(_ row: Row) -> BundledFood {
        BundledFood(
            id: row["id"], sourceID: row["source_id"], name: row["name"],
            per100: Nutrients(
                kcal: row["kcal_100"], proteinG: row["protein_g_100"], carbsG: row["carbs_g_100"], fatG: row["fat_g_100"],
                fiberG: row["fiber_g_100"], sugarG: row["sugar_g_100"], satFatG: row["sat_fat_g_100"], sodiumMg: row["sodium_mg_100"],
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

    /// Source badge (FR-20): custom, recipe, bundled (USDA), off, usda.
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

    public init(_ database: AppDatabase, bundled: BundledFoodIndex?) {
        self.database = database
        self.bundled = bundled
    }

    /// User foods first — foods already logged before unused ones, then by FTS rank (bm25), use count and
    /// recency — followed by bundled foods that have no local copy yet. Prefix matching, case- and
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

        let copied = Set(foods.filter { $0.source == .bundled }.compactMap(\.sourceID))
        let alreadyLocal = try database.reader.read { db in
            try Set(String.fetchAll(db, sql: "SELECT source_id FROM food WHERE source = 'bundled' AND source_id IS NOT NULL"))
        }
        for item in try bundled.search(query, limit: limit) where !copied.contains(item.sourceID) && !alreadyLocal.contains(item.sourceID) {
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
        let terms = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
