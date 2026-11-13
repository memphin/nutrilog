import Core
import Foundation
import GRDB

/// Registers every schema migration in order. Never edit a shipped migration —
/// add a new numbered `.sql` file to `Migrations/` and register it here. A data repair that needs more than SQL is
/// written in Swift instead: list its name here and return its body from `codedMigration(named:deviceCalendar:)`.
public enum Migrator {
    public static let migrations: [String] = [
        "001_initial",
        "002_food_last_quantity",
        "003_off_product_cache_not_found",
        "004_food_per_serving_only",
        "005_healthkit_outbox",
        "006_barcode_scan_log",
        "007_tdee_estimate_details",
        "008_recipes_to_foods",
        "009_planned_entry",
        "010_caffeine",
        "011_gregorian_days", // Swift-coded, see `codedMigration`
        "012_food_merged_into",
        "013_hydration", // `013_hydration.sql` plus Swift-coded backfills, see `codedMigration`
        "014_caffeine_ml", // Swift-coded, see `codedMigration`
        "015_training_days",
        "016_drop_barcode_scan_log",
        "017_supplements",
        "018_health_workout",
        // "019_<description>",
    ]

    /// `deviceCalendar`: the calendar the device uses now, which migration 011 needs to tell which calendar the
    /// stored days were written in. The default is read here, at the one place the migrator is built for the app.
    public static func make(deviceCalendar: Calendar.Identifier = Calendar.current.identifier) throws -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = false // keep false: we want real migrations even in debug
        #endif
        for name in migrations {
            if let migrate = codedMigration(named: name, deviceCalendar: deviceCalendar) {
                migrator.registerMigration(name, migrate: migrate)
            } else {
                migrator.registerMigration(name) { db in
                    try db.execute(sql: Self.sql(named: name))
                }
            }
        }
        return migrator
    }

    /// The body of a migration written in Swift, or nil for a bundled `.sql` migration.
    static func codedMigration(
        named name: String, deviceCalendar: Calendar.Identifier,
    ) -> (@Sendable (Database) throws -> Void)? {
        switch name {
        case "011_gregorian_days":
            // Days written before `LocalDay` always used the Gregorian calendar (e.g. "2569-11-11" on a Buddhist iPhone).
            { db in
                let now = Date()
                try StoredDayMigration.run(db, deviceCalendar: deviceCalendar, today: LocalDay(now), now: now)
            }
        case "013_hydration":
            // The schema from the bundled SQL, then backfills the importer also runs on older exports.
            { db in try HydrationBackfill.migrate(db) }
        case "014_caffeine_ml":
            // Drink volumes of existing caffeine quick-adds come from the presets, which live in Core.
            { db in try CaffeineMlMigration.run(db) }
        default:
            nil
        }
    }

    static func sql(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sql", subdirectory: "Migrations") else {
            throw MigrationError.missingFile(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public enum MigrationError: Error { case missingFile(String) }
}
