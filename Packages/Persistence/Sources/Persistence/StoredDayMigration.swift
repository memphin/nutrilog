import Core
import Foundation
import GRDB

/// Moves days stored under a non-Gregorian device calendar to their Gregorian day (migration 011, and after every JSON
/// import, since a backup made before the fix holds the same days). See `StoredDayRepair` for which values are
/// converted; anything it can't convert with certainty is left as it is.
///
/// Repaired: `diary_entry.day`, `planned_entry.day`, `water_entry.day`, `caffeine_entry.day`, `day_note.day`,
/// `daily_metrics.day`,
/// `target.effective_from`, `tdee_estimate.computed_for_day`, the days inside `tdee_estimate.details_json`,
/// `profile.birth_date` (with the birth-date window) and "YYYY-MM-DD" strings inside `setting.value` (e.g. the
/// check-in prompt day). Changed rows get `updated_at = now` and `revision + 1` where the table has them; nothing is
/// queued for Apple Health (nutrients and timestamps don't change). A database with only Gregorian days is not written.
///
/// Where a repaired day already has a row (written after the fix):
/// - `daily_metrics`: a cache rebuilt from Health — the existing row stays, the stale one is deleted (with several
///   stale rows and no existing one, the most recently fetched is kept).
/// - `day_note`: one row per day — the texts of the live notes are joined (oldest first, a text already contained is
///   not repeated), `is_complete` is OR-ed; the other rows are deleted. Tombstones count as no content.
/// - `target`: the app keeps one live target per `effective_from` — the most recently updated live one stays, the
///   others are soft-deleted (`deleted_at`), so nothing disappears from a sync log.
/// - `tdee_estimate`: a second check-in on a day replaces the first (`CheckInRepository.record`) — the most recently
///   updated row stays, the others are deleted (the table has no tombstones).
/// - `diary_entry`, `planned_entry`, `water_entry`, `caffeine_entry`: many rows per day are normal; every row is kept.
enum StoredDayMigration {
    /// Runs the repair in `db`'s current transaction. Returns the number of rows changed or deleted.
    @discardableResult
    static func run(_ db: Database, deviceCalendar: Calendar.Identifier, today: LocalDay, now: Date) throws -> Int {
        let context = Context(
            deviceCalendar: deviceCalendar,
            activity: .activity(today: today),
            birthDate: .birthDate(today: today),
            stamp: Timestamp.string(now),
        )
        var changes = 0
        for table in ["diary_entry", "planned_entry", "water_entry", "caffeine_entry"] where try db.tableExists(table) {
            changes += try repairPlainDays(db, table: table, context)
        }
        changes += try repairDayNotes(db, context)
        changes += try repairDailyMetrics(db, context)
        changes += try repairTargets(db, context)
        changes += try repairCheckIns(db, context)
        changes += try repairBirthDate(db, context)
        changes += try repairSettings(db, context)
        return changes
    }

    struct Context {
        var deviceCalendar: Calendar.Identifier
        var activity: StoredDayRepair.Scope
        var birthDate: StoredDayRepair.Scope
        var stamp: String

        func repaired(_ stored: String?) -> String? {
            guard let stored,
                  let day = StoredDayRepair.repairedDay(stored, deviceCalendar: deviceCalendar, scope: activity)?.isoString,
                  day != stored else { return nil }
            return day
        }

        func repairedJSON(_ json: String?) -> String? {
            json.flatMap { StoredDayRepair.repairingDays(inJSON: $0, deviceCalendar: deviceCalendar, scope: activity) }
        }
    }

    /// Stale day values grouped by the Gregorian day they repair to (two calendars can land on the same day).
    static func staleDays(_ db: Database, table: String, column: String, _ context: Context) throws -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for stored in try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL") {
            if let day = context.repaired(stored) {
                groups[day, default: []].append(stored)
            }
        }
        return groups
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    // MARK: Tables without a day-uniqueness rule

    static func repairPlainDays(_ db: Database, table: String, _ context: Context) throws -> Int {
        var changes = 0
        for (day, stale) in try staleDays(db, table: table, column: "day", context) {
            try db.execute(
                sql: "UPDATE \(table) SET day = ?, updated_at = ?, revision = revision + 1 WHERE day IN (\(placeholders(stale.count)))",
                arguments: StatementArguments([day, context.stamp] + stale),
            )
            changes += db.changesCount
        }
        return changes
    }

    // MARK: day_note (PRIMARY KEY day)

    static func repairDayNotes(_ db: Database, _ context: Context) throws -> Int {
        var changes = 0
        for (day, stale) in try staleDays(db, table: "day_note", column: "day", context).sorted(by: { $0.key < $1.key }) {
            let staleRows = try Row.fetchAll(
                db, sql: "SELECT * FROM day_note WHERE day IN (\(placeholders(stale.count))) ORDER BY created_at, day",
                arguments: StatementArguments(stale),
            )
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM day_note WHERE day = ?", arguments: [day])
            // Content in chronological order: the stale rows were written before the fix, the existing one after.
            let live = (staleRows + [existing].compactMap(\.self)).filter { ($0["deleted_at"] as String?) == nil }
            // A stale text already contained in the existing note (e.g. merged by an earlier import) isn't added again.
            let existingText: String = existing.flatMap { ($0["deleted_at"] as String?) == nil ? $0["text"] : nil } ?? ""
            var pieces: [String] = []
            for row in live where (row["day"] as String) != day {
                let piece: String = row["text"]
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !existingText.contains(trimmed), !pieces.contains(where: { $0.contains(trimmed) })
                else { continue }
                pieces.append(piece)
            }
            if !existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(existingText)
            }
            let text = pieces.joined(separator: "\n\n")
            let isComplete = live.contains { $0["is_complete"] as Bool }

            // The row that survives: the existing one, else the first live stale row, else the first stale row.
            let keeper = existing ?? live.first ?? staleRows[0]
            let keeperDay: String = keeper["day"]
            for row in staleRows where (row["day"] as String) != keeperDay {
                try db.execute(sql: "DELETE FROM day_note WHERE day = ?", arguments: [row["day"] as String])
                changes += 1
            }
            var newText: String = keeper["text"]
            var newComplete: Bool = keeper["is_complete"]
            var deletedAt: String? = keeper["deleted_at"]
            if !live.isEmpty {
                newText = text.isEmpty ? newText : text
                newComplete = isComplete
                deletedAt = nil
            }
            let unchanged = keeperDay == day && newText == keeper["text"] && newComplete == keeper["is_complete"]
                && deletedAt == keeper["deleted_at"]
            guard !unchanged else { continue }
            try db.execute(
                sql: """
                UPDATE day_note SET day = ?, text = ?, is_complete = ?, deleted_at = ?, updated_at = ?, revision = revision + 1
                WHERE day = ?
                """,
                arguments: [day, newText, newComplete, deletedAt, context.stamp, keeperDay],
            )
            changes += 1
        }
        return changes
    }

    // MARK: daily_metrics (PRIMARY KEY day, a cache)

    static func repairDailyMetrics(_ db: Database, _ context: Context) throws -> Int {
        var changes = 0
        for (day, stale) in try staleDays(db, table: "daily_metrics", column: "day", context) {
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM daily_metrics WHERE day = ?)", arguments: [day]) ?? false
            var doomed = stale
            if !exists {
                let freshest = try String.fetchOne(
                    db, sql: "SELECT day FROM daily_metrics WHERE day IN (\(placeholders(stale.count))) ORDER BY fetched_at DESC, day LIMIT 1",
                    arguments: StatementArguments(stale),
                )!
                doomed.removeAll { $0 == freshest }
                try db.execute(sql: "DELETE FROM daily_metrics WHERE day IN (\(placeholders(doomed.count)))", arguments: StatementArguments(doomed))
                changes += db.changesCount
                try db.execute(
                    sql: "UPDATE daily_metrics SET day = ?, updated_at = ?, revision = revision + 1 WHERE day = ?",
                    arguments: [day, context.stamp, freshest],
                )
                changes += db.changesCount
            } else {
                try db.execute(sql: "DELETE FROM daily_metrics WHERE day IN (\(placeholders(doomed.count)))", arguments: StatementArguments(doomed))
                changes += db.changesCount
            }
        }
        return changes
    }

    // MARK: target (one live row per effective_from)

    static func repairTargets(_ db: Database, _ context: Context) throws -> Int {
        var changes = 0
        for (day, stale) in try staleDays(db, table: "target", column: "effective_from", context) {
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, effective_from, updated_at, deleted_at FROM target WHERE effective_from IN (\(placeholders(stale.count + 1)))",
                arguments: StatementArguments(stale + [day]),
            )
            let live = rows.filter { ($0["deleted_at"] as String?) == nil }
            let winner = live.max { ($0["updated_at"] as String, $0["id"] as String) < ($1["updated_at"] as String, $1["id"] as String) }
            let losers = Set(live.map { $0["id"] as String }).subtracting([winner?["id"] as String?].compactMap(\.self))
            for row in rows {
                let id: String = row["id"]
                let isStale = (row["effective_from"] as String) != day
                let retire = losers.contains(id)
                guard isStale || retire else { continue }
                try db.execute(
                    sql: """
                    UPDATE target SET effective_from = ?, deleted_at = COALESCE(deleted_at, ?), updated_at = ?, revision = revision + 1
                    WHERE id = ?
                    """,
                    arguments: [day, retire ? context.stamp : nil, context.stamp, id],
                )
                changes += db.changesCount
            }
        }
        return changes
    }

    // MARK: tdee_estimate (one check-in per day; days inside details_json)

    static func repairCheckIns(_ db: Database, _ context: Context) throws -> Int {
        var changes = 0
        for (day, stale) in try staleDays(db, table: "tdee_estimate", column: "computed_for_day", context) {
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, updated_at FROM tdee_estimate WHERE computed_for_day IN (\(placeholders(stale.count + 1)))",
                arguments: StatementArguments(stale + [day]),
            )
            let winner = rows.max { ($0["updated_at"] as String, $0["id"] as String) < ($1["updated_at"] as String, $1["id"] as String) }
            for row in rows where (row["id"] as String) != (winner?["id"] as String?) {
                try db.execute(sql: "DELETE FROM tdee_estimate WHERE id = ?", arguments: [row["id"] as String])
                changes += db.changesCount
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, computed_for_day, details_json FROM tdee_estimate") {
            let day = context.repaired(row["computed_for_day"])
            let details = context.repairedJSON(row["details_json"])
            guard day != nil || details != nil else { continue }
            try db.execute(
                sql: """
                UPDATE tdee_estimate SET computed_for_day = COALESCE(?, computed_for_day), details_json = COALESCE(?, details_json),
                    updated_at = ?, revision = revision + 1
                WHERE id = ?
                """,
                arguments: [day, details, context.stamp, row["id"] as String],
            )
            changes += db.changesCount
        }
        return changes
    }

    // MARK: profile.birth_date, setting.value

    static func repairBirthDate(_ db: Database, _ context: Context) throws -> Int {
        guard let stored = try String.fetchOne(db, sql: "SELECT birth_date FROM profile WHERE id = 1"),
              let day = StoredDayRepair.repairedDay(stored, deviceCalendar: context.deviceCalendar, scope: context.birthDate)?.isoString,
              day != stored else { return 0 }
        try db.execute(
            sql: "UPDATE profile SET birth_date = ?, updated_at = ?, revision = revision + 1 WHERE id = 1",
            arguments: [day, context.stamp],
        )
        return db.changesCount
    }

    static func repairSettings(_ db: Database, _ context: Context) throws -> Int {
        var changes = 0
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM setting") {
            guard let value = context.repairedJSON(row["value"]) else { continue }
            try db.execute(sql: "UPDATE setting SET value = ?, updated_at = ? WHERE key = ?", arguments: [value, context.stamp, row["key"] as String])
            changes += db.changesCount
        }
        return changes
    }
}
