import Core
import GRDB

/// Migration 014: fills `caffeine_entry.ml` of existing quick-adds from their preset's serving (Core
/// `CaffeineDrink.servingMl`), which SQL can't see. Custom amounts and ids no preset has any more stay NULL.
enum CaffeineMlMigration {
    /// Runs in `db`'s current transaction. Returns the number of rows changed.
    @discardableResult
    static func run(_ db: Database) throws -> Int {
        var changes = 0
        for drink in CaffeineDrink.all where drink.servingMl != nil { // a pill has no volume
            try db.execute(
                sql: "UPDATE caffeine_entry SET ml = ? WHERE drink_id = ? AND ml IS NULL",
                arguments: [drink.servingMl, drink.id],
            )
            changes += db.changesCount
        }
        return changes
    }
}
