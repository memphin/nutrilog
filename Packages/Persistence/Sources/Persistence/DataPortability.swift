import Core
import Foundation
import GRDB

/// Full-fidelity JSON export / import and CSV export (FR-60, FR-61, backlog #13, #14).
///
/// The JSON contains every user-data table, tombstones included, rows ordered by primary key and keys sorted,
/// so exporting → restoring into an empty database → exporting again yields identical bytes.
public struct DataPortability: Sendable {
    public static let format = "vitalion-export"
    /// What exports were called while the app was named Nutrilog; still accepted on import.
    static let legacyFormats: Set<String> = ["nutrilog-export"]

    /// Tables in foreign-key-safe insertion order. `off_product_cache` is a re-fetchable cache of ODbL data and
    /// is deliberately excluded, as is `healthkit_outbox` (this device's queue of pending Apple Health writes).
    static let tables = [
        "meal_slot", "food", "serving", "food_barcode", "recipe_ingredient", "meal_template", "meal_template_item",
        "diary_entry", "planned_entry", "healthkit_link", "day_note", "water_entry", "caffeine_entry", "weight_entry",
        "daily_metrics", "profile", "target", "training_schedule", "training_day", "tdee_estimate", "setting",
    ]

    public enum ImportMode: Sendable {
        /// Wipes all user data first, then inserts the file's rows.
        case replace
        /// Keeps local rows; for rows present in both, the newer `updated_at` wins (last-writer-wins), except that an
        /// edited incoming profile / default meal slot always replaces a never-edited install seed.
        case merge
    }

    public struct ImportSummary: Equatable, Sendable {
        public var inserted = 0
        public var updated = 0
        public var skipped = 0
    }

    public enum ImportError: Error, Equatable, Sendable {
        case notAnExport
        case newerSchema(file: Int, supported: Int)
        case unknownTable(String)
        /// Replace would leave no profile or no meal slots (partial or hand-edited file); nothing was changed.
        case incompleteBackup
    }

    let database: AppDatabase
    let clock: AppClock
    /// The device calendar now, for repairing days a pre-fix backup stored in it (see `StoredDayMigration`).
    let deviceCalendar: Calendar.Identifier

    public init(
        _ database: AppDatabase, clock: AppClock = .system, deviceCalendar: Calendar.Identifier = Calendar.current.identifier,
    ) {
        self.database = database
        self.clock = clock
        self.deviceCalendar = deviceCalendar
    }

    public static var schemaVersion: Int {
        Migrator.migrations.count
    }

    // MARK: JSON export

    public func exportJSON() throws -> Data {
        let exportedAt = Timestamp.string(clock.now())
        let tables = try database.reader.read { db in
            var result: [String: [[String: JSONValue]]] = [:]
            for table in Self.tables {
                let pk = try db.primaryKey(table).columns.joined(separator: ", ")
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(pk)")
                let notNull = try Set(db.columns(in: table).filter(\.isNotNull).map(\.name))
                result[table] = rows.map { row in
                    var object: [String: JSONValue] = [:]
                    for column in row.columnNames {
                        var value = JSONValue(row[column] as DatabaseValue)
                        // JSON has no infinity (JSONEncoder throws), and one bad row must not stop every backup:
                        // a non-finite REAL (stored before amounts were validated) is written as null or, where the
                        // column can't hold null, clamped to the entry limit (which also passes `CHECK (x > 0)`), so
                        // the file still restores and the odd row stays visible to fix.
                        if case let .double(number) = value, !number.isFinite {
                            value = if notNull.contains(column), !number.isNaN {
                                .double(number < 0 ? -EntryLimits.maxAmount : EntryLimits.maxAmount)
                            } else {
                                .null
                            }
                        }
                        object[column] = value
                    }
                    return object
                }
            }
            return result
        }
        let file = ExportFile(format: Self.format, schemaVersion: Self.schemaVersion, exportedAt: exportedAt, tables: tables)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    // MARK: JSON import

    @discardableResult
    public func importJSON(_ data: Data, mode: ImportMode) throws -> ImportSummary {
        let file: ExportFile
        do {
            file = try JSONDecoder().decode(ExportFile.self, from: data)
        } catch {
            throw ImportError.notAnExport
        }
        guard file.format == Self.format || Self.legacyFormats.contains(file.format) else { throw ImportError.notAnExport }
        guard file.schemaVersion <= Self.schemaVersion else {
            throw ImportError.newerSchema(file: file.schemaVersion, supported: Self.schemaVersion)
        }
        if let unknown = file.tables.keys.first(where: { !Self.tables.contains($0) }) {
            throw ImportError.unknownTable(unknown)
        }

        let now = clock.now()
        return try database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            var summary = ImportSummary()
            // Rows whose Apple Health copy must follow the import (backlog #27), queued in this transaction.
            var healthChanges: [HealthKitOwner: [String]] = [:]
            // Tables with rows taken from the file (inserted or updated), for the repairs of older exports.
            var importedTables: Set<String> = []
            if mode == .replace {
                // The wipe drops `healthkit_link`; queue every row that has samples first, so samples of rows the
                // backup doesn't contain (logged after it was made) are deleted instead of stranded in Health.
                try HealthKitLinkRepository.enqueueLinkedOwners(db, now: now)
                for table in Self.tables.reversed() {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
            for table in Self.tables {
                guard let rows = file.tables[table] else { continue }
                let healthOwner = HealthKitOwner(rawValue: table)
                let pkColumns = try db.primaryKey(table).columns
                let columns = try Set(db.columns(in: table).map(\.name))
                let hasUpdatedAt = columns.contains("updated_at")
                for row in rows {
                    let values = row.filter { columns.contains($0.key) }
                    let keyClause = pkColumns.map { "\($0) = ?" }.joined(separator: " AND ")
                    let keyArgs = StatementArguments(pkColumns.map { values[$0]?.databaseValue ?? .null })
                    let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(keyClause)", arguments: keyArgs)
                    let names = values.keys.sorted()
                    let args = StatementArguments(names.map { values[$0]!.databaseValue })
                    if existing == nil {
                        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
                        // Merge: a row clashing with a local row on another unique key (e.g. healthkit_link.hk_uuid)
                        // is skipped instead of aborting the whole import; local data wins. `ON CONFLICT DO NOTHING`
                        // (unlike `OR IGNORE`) only covers uniqueness, so NOT NULL / CHECK violations still abort.
                        let onConflict = mode == .merge ? " ON CONFLICT DO NOTHING" : ""
                        try db.execute(
                            sql: "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))\(onConflict)",
                            arguments: args,
                        )
                        if db.changesCount > 0 {
                            summary.inserted += 1
                            importedTables.insert(table)
                            if let healthOwner, let id = values["id"]?.stringValue {
                                healthChanges[healthOwner, default: []].append(id)
                            }
                        } else {
                            summary.skipped += 1
                        }
                    } else if let existing, hasUpdatedAt,
                              let incoming = values["updated_at"]?.stringValue,
                              let local: String = existing["updated_at"],
                              incoming > local || Self.replacesSeed(table: table, local: existing, incoming: values)
                    {
                        // UPDATE (not INSERT OR REPLACE) so ON DELETE CASCADE children are kept.
                        let assignments = names.map { "\($0) = ?" }.joined(separator: ", ")
                        try db.execute(sql: "UPDATE \(table) SET \(assignments) WHERE \(keyClause)", arguments: args + keyArgs)
                        summary.updated += 1
                        importedTables.insert(table)
                        if let healthOwner, let id = values["id"]?.stringValue {
                            healthChanges[healthOwner, default: []].append(id)
                        }
                    } else {
                        summary.skipped += 1
                    }
                }
            }
            // Exports made before recipes were removed (issue #68) may hold recipe foods: like migration 008, they
            // become ordinary custom foods.
            try db.execute(
                sql: "UPDATE food SET source = ?, updated_at = ?, revision = revision + 1 WHERE source = ?",
                arguments: [FoodSource.custom.rawValue, Timestamp.string(now), FoodSource.recipe.rawValue],
            )
            // Exports made before hydration tracking: like migrations 013 and 014. The file's diary entries are the
            // inserted and updated ones, whose Health samples follow too.
            try Self.repairHydration(
                db, schemaVersion: file.schemaVersion, diaryIDs: healthChanges[.diaryEntry] ?? [],
                profileImported: importedTables.contains("profile"),
            )
            // Exports made before `LocalDay` always used the Gregorian calendar may hold days in the device calendar
            // (e.g. "2569-11-11" on a Buddhist iPhone): like migration 011, they move to their Gregorian day.
            try StoredDayMigration.run(db, deviceCalendar: deviceCalendar, today: LocalDay(now), now: now)
            // Replace wipes every table, so a partial file must not leave the app without a profile or meal slots.
            // Checking the result (not the file's keys) keeps older, smaller-schema backups importable.
            if mode == .replace {
                let profiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile") ?? 0
                let slots = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meal_slot") ?? 0
                if profiles == 0 || slots == 0 {
                    throw ImportError.incompleteBackup // rolls back the transaction
                }
                // Every active row is written again (the writer deletes by entry id first, so nothing doubles).
                try HealthKitLinkRepository.enqueueActiveOwners(db, now: now)
            } else {
                // Merge: inserted and newer (updated) diary / water rows — deleted ones included, so their samples go.
                for (owner, ids) in healthChanges.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    try HealthKitLinkRepository.enqueue(db, owner: owner, ids: ids, now: now)
                }
            }
            return summary
        }
    }

    /// Exports made before hydration tracking have no fluid volumes and no goal mode: like migrations 013 and 014, the
    /// file's diary entries of drinks (`diaryIDs`) and caffeine drinks get their volume, and the file's profile its goal
    /// mode. Local rows the file didn't replace (merge) keep theirs.
    static func repairHydration(_ db: Database, schemaVersion: Int, diaryIDs: [String], profileImported: Bool) throws {
        if predates(schemaVersion, migration: "013_hydration") {
            try HydrationBackfill.diaryFluid(db, entryIDs: diaryIDs)
            if profileImported {
                try HydrationBackfill.goalMode(db)
            }
        }
        if predates(schemaVersion, migration: "014_caffeine_ml") {
            try CaffeineMlMigration.run(db) // only preset drinks without a volume, which only an old file has
        }
    }

    /// Whether a file of `schemaVersion` (the number of migrations its app had run) was exported before `migration`.
    static func predates(_ schemaVersion: Int, migration: String) -> Bool {
        guard let index = Migrator.migrations.firstIndex(of: migration) else { return false }
        return schemaVersion <= index
    }

    /// Rows migration 001 seeds on install (the profile and the default meal slots), keyed by table.
    static let seededRows: [String: Set<String>] = [
        "profile": ["1"],
        "meal_slot": ["breakfast", "lunch", "dinner", "snacks"],
    ]

    /// Merge: whether `incoming` replaces `local` although it is older. Seeds are stamped with the install time, so
    /// on a new phone they are always newer than the backup and plain last-writer-wins would drop the profile and
    /// slot edits. A seed nobody edited still has `revision = 1` (every save bumps it), so an edited incoming row
    /// (`revision > 1`) wins over it.
    static func replacesSeed(table: String, local: Row, incoming: [String: JSONValue]) -> Bool {
        guard let seeds = seededRows[table] else { return false }
        let key: DatabaseValue = local["id"]
        let id: String? = switch key.storage {
        case let .int64(value): String(value)
        case let .string(value): value
        default: nil
        }
        guard let id, seeds.contains(id),
              let localRevision: Int = local["revision"], localRevision <= 1,
              case let .int(incomingRevision)? = incoming["revision"], incomingRevision > 1
        else { return false }
        return true
    }

    // MARK: CSV export

    /// Files for the share sheet: `diary.csv` (active entries) and `weights.csv` (manual weights).
    /// Comma-separated, dot decimals, RFC 4180 quoting.
    public func exportCSV() throws -> [String: String] {
        try database.reader.read { db in
            var diary = [[
                "day", "meal", "food", "amount", "unit", "serving", "kcal", "protein_g", "carbs_g", "fat_g",
                "fiber_g", "sugar_g", "sat_fat_g", "sodium_mg", "caffeine_mg", "quick_add", "note",
            ]]
            let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, s.name AS slot_name, s.sort_order AS slot_order, COALESCE(f.is_liquid, 0) AS liquid
            FROM diary_entry e
            JOIN meal_slot s ON s.id = e.meal_slot_id
            LEFT JOIN food f ON f.id = e.food_id
            WHERE e.deleted_at IS NULL
            ORDER BY e.day, slot_order, e.sort_order, e.logged_at
            """)
            for row in rows {
                let isQuickAdd: Bool = row["is_quick_add"]
                let liquid: Bool = row["liquid"]
                diary.append([
                    row["day"], row["slot_name"], row["display_name"],
                    isQuickAdd ? "" : Self.number(row["grams"]), isQuickAdd ? "" : (liquid ? "ml" : "g"),
                    row["serving_label"] ?? "",
                    Self.number(row["kcal"]), Self.number(row["protein_g"]), Self.number(row["carbs_g"]), Self.number(row["fat_g"]),
                    Self.number(row["fiber_g"]), Self.number(row["sugar_g"]), Self.number(row["sat_fat_g"]), Self.number(row["sodium_mg"]),
                    Self.number(row["caffeine_mg"]), isQuickAdd ? "1" : "0", row["note"] ?? "",
                ])
            }

            var weights = [["measured_at", "kg", "body_fat_pct", "source"]]
            for entry in try WeightEntry.filter(WeightEntry.Columns.deletedAt == nil).order(WeightEntry.Columns.measuredAt).fetchAll(db) {
                weights.append([Timestamp.string(entry.measuredAt), Self.number(entry.kg), Self.number(entry.bodyFatPct), entry.source])
            }
            return ["diary.csv": Self.csv(diary), "weights.csv": Self.csv(weights)]
        }
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return NumberFormatting.compact(value)
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { fields in
            fields.map { raw in
                let field = neutralizeFormula(raw)
                // Unicode scalars, not Characters: "\r\n" is a single Character equal to neither "\r" nor "\n".
                guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                else { return field }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    /// Spreadsheets execute cells starting with `= + - @` (or tab/CR) as formulas; prefix such text with `'`.
    /// Plain numbers (e.g. "-5") are left alone.
    static func neutralizeFormula(_ field: String) -> String {
        let trimmed = field.drop(while: { $0 == " " })
        guard let first = trimmed.unicodeScalars.first, "=+-@\t\r\n＝＋－＠".unicodeScalars.contains(first),
              Double(field) == nil else { return field }
        return "'" + field
    }
}

// MARK: - File format

struct ExportFile: Codable {
    var format: String
    var schemaVersion: Int
    var exportedAt: String
    var tables: [String: [[String: JSONValue]]]
}

/// A JSON scalar mirroring SQLite storage classes.
enum JSONValue: Codable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case let .int64(i): self = .int(i)
        case let .double(d): self = .double(d)
        case let .string(s): self = .string(s)
        case let .blob(b): self = .string(b.base64EncodedString())
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case let .int(i): i.databaseValue
        case let .double(d): d.databaseValue
        case let .string(s): s.databaseValue
        }
    }

    var stringValue: String? {
        if case let .string(s) = self {
            return s
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = try .string(c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        }
    }
}
