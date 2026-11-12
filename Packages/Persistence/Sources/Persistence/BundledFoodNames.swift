import Core
import Foundation
import GRDB

public extension FoodRepository {
    /// Switches the names stored from bundled foods to `language` (Settings → Food names, FR-74), using both names
    /// from `index`:
    ///
    /// - Copies of bundled foods, and USDA copies of the same FDC id, whose name is exactly one of the two names
    ///   get the name in `language` and the other one as `nameLocal`. A name the user changed stays, as do custom
    ///   and Open Food Facts foods.
    /// - Diary and planned entries of those foods (by the food's FDC id) whose `display_name` is exactly one of the
    ///   two names get the name in `language`. Saved meals show the food's own name, so they follow the copy.
    ///
    /// Deleted rows switch too, so an undo or a revived copy shows the chosen language. Every changed row gets a new
    /// `updated_at` / `revision`; nothing is queued for Apple Health, so samples already written keep their name.
    /// Idempotent and cheap: run it when the setting changes and at every launch. Returns the number of rows changed.
    @discardableResult
    func applyBundledNames(_ language: FoodNameLanguage, from index: BundledFoodIndex) throws -> Int {
        try applyBundledNames(from: index) { _ in language }.changes
    }

    /// Like ``applyBundledNames(_:from:)``, but reads Settings → Food names (the `setting` row `preferenceKey`)
    /// inside the same write. Writes run one at a time, so whichever switch writes last applies the latest choice:
    /// a switch started at launch can't undo a change made right after. Returns the language applied and the number
    /// of rows changed.
    @discardableResult
    func applyBundledNames(
        from index: BundledFoodIndex,
        preferenceKey: String,
        appLanguage: FoodNameLanguage,
    ) throws -> (language: FoodNameLanguage, changes: Int) {
        try applyBundledNames(from: index) { db in
            let raw = try? ProfileRepository.setting(db, preferenceKey, as: String.self)
            return (raw.flatMap(FoodNamePreference.init(rawValue:)) ?? .default).resolved(appLanguage: appLanguage)
        }
    }

    private func applyBundledNames(
        from index: BundledFoodIndex,
        resolve: @escaping @Sendable (Database) throws -> FoodNameLanguage,
    ) throws -> (language: FoodNameLanguage, changes: Int) {
        let names = try index.bilingualNames()
        let now = clock.now()
        return try database.writer.write { db in
            let language = try resolve(db)
            guard !names.isEmpty else { return (language, 0) }
            var changes = 0
            let copies = try Food
                .filter([FoodSource.bundled, .usda].contains(Food.Columns.source) && Food.Columns.sourceID != nil)
                .fetchAll(db)
            for var food in copies {
                guard let sourceID = food.sourceID, let bilingual = names[sourceID],
                      let switched = bilingual.switching(name: food.name, nameLocal: food.nameLocal, to: language)
                else { continue }
                food.name = switched.name
                food.nameLocal = switched.nameLocal
                food.stampUpdated(now)
                try food.update(db)
                changes += 1
            }
            let stamp = Timestamp.string(now)
            for table in ["diary_entry", "planned_entry"] {
                let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.display_name, f.source_id FROM \(table) e JOIN food f ON f.id = e.food_id
                WHERE f.source IN ('bundled', 'usda') AND f.source_id IS NOT NULL
                """)
                for row in rows {
                    guard let bilingual = names[row["source_id"] as String],
                          let name = bilingual.switchingSnapshot(row["display_name"], to: language)
                    else { continue }
                    try db.execute(
                        sql: "UPDATE \(table) SET display_name = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                        arguments: [name, stamp, row["id"] as String],
                    )
                    changes += 1
                }
            }
            return (language, changes)
        }
    }
}
