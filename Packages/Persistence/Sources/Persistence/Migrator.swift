import Foundation
import GRDB

/// Registers every schema migration in order. Never edit a shipped migration —
/// add a new numbered `.sql` file to `Migrations/` and register it here.
public enum Migrator {
    public static let migrations: [String] = [
        "001_initial",
        "002_food_last_quantity",
        "003_off_product_cache_not_found",
        "004_food_per_serving_only",
        "005_healthkit_outbox",
        "006_barcode_scan_log",
        // "007_<description>",
    ]

    public static func make() throws -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = false // keep false: we want real migrations even in debug
        #endif
        for name in migrations {
            migrator.registerMigration(name) { db in
                try db.execute(sql: Self.sql(named: name))
            }
        }
        return migrator
    }

    static func sql(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sql", subdirectory: "Migrations") else {
            throw MigrationError.missingFile(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public enum MigrationError: Error { case missingFile(String) }
}
