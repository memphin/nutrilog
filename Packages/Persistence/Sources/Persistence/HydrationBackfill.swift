import GRDB

/// The data repairs of migration 013 (`013_hydration`), shared with the importer, which runs them again on rows of an
/// export made before 013. Keep them frozen like a shipped migration: they say what an app before hydration meant.
enum HydrationBackfill {
    /// Migration 013 in full: the schema changes of `013_hydration.sql`, then both backfills on every row.
    static func migrate(_ db: Database) throws {
        try db.execute(sql: Migrator.sql(named: "013_hydration"))
        try diaryFluid(db)
        try goalMode(db)
    }

    /// Existing entries of drinks under the automatic rule (liquid foods with at most 50 g fat per 100 ml; active and
    /// deleted entries) get `fluid_ml = grams`. Entries whose food row is gone, quick-adds and 0 g entries are left
    /// alone. `entryIDs` limits the repair to those entries; nil repairs every entry.
    static func diaryFluid(_ db: Database, entryIDs: [String]? = nil) throws {
        let sql = """
        UPDATE diary_entry SET fluid_ml = grams
        WHERE food_id IN (SELECT id FROM food WHERE is_liquid = 1 AND fat_g_100 <= 50) AND grams > 0
        """
        guard let entryIDs else {
            try db.execute(sql: sql)
            return
        }
        // Chunks keep each statement well below SQLite's limit on bound parameters.
        for start in stride(from: 0, to: entryIDs.count, by: 500) {
            let chunk = Array(entryIDs[start ..< min(start + 500, entryIDs.count)])
            try db.execute(
                sql: sql + " AND id IN (\(databaseQuestionMarks(count: chunk.count)))",
                arguments: StatementArguments(chunk),
            )
        }
    }

    /// A water goal the user changed from the 2500 ml default stays as their fixed amount (`'fixed'`); everyone else
    /// gets the weight-based goal (`'weight'`).
    static func goalMode(_ db: Database) throws {
        try db.execute(sql: """
        UPDATE profile SET water_goal_mode = CASE WHEN water_goal_ml <> 2500 THEN 'fixed' ELSE 'weight' END
        """)
    }
}
