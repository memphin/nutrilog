import Core
import Foundation
import GRDB

/// Everything drunk, from the three places drinks are logged, as one list of `FluidIntake` per day: water quick-adds
/// (`water_entry`), diary entries with a fluid snapshot (`diary_entry.fluid_ml > 0`) and caffeine quick-adds with a
/// volume (`caffeine_entry.ml > 0`). Read-only: each source is edited through its own repository.
public struct HydrationRepository: Sendable {
    let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// The active intakes of every day in `days`, each day sorted by time (then id). Days without any are absent.
    public func intakes(in days: ClosedRange<LocalDay>) throws -> [LocalDay: [FluidIntake]] {
        try database.reader.read { db in try Self.intakes(db, in: days) }
    }

    /// ``intakes(in:)`` now and after every change to any of the three sources.
    public func observeIntakes(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[LocalDay: [FluidIntake]]> {
        database.observe { db in try Self.intakes(db, in: days) }
    }

    /// Names of intakes that carry none of their own, in the app's language when read.
    static var waterName: String {
        String(localized: "Water", bundle: .module)
    }

    static var caffeineName: String {
        String(localized: "Caffeine", bundle: .module)
    }

    static func intakes(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [LocalDay: [FluidIntake]] {
        var result: [LocalDay: [FluidIntake]] = [:]
        let range: StatementArguments = [days.lowerBound, days.upperBound]
        func add(_ day: LocalDay, _ intake: FluidIntake) {
            result[day, default: []].append(intake)
        }

        for entry in try WaterEntry
            .filter(WaterEntry.Columns.day >= days.lowerBound && WaterEntry.Columns.day <= days.upperBound)
            .filter(WaterEntry.Columns.deletedAt == nil)
            .fetchAll(db)
        {
            add(entry.day, FluidIntake(id: entry.id, ml: entry.ml, at: entry.loggedAt, kind: .water, source: .water, name: Self.waterName))
        }

        for row in try Row.fetchAll(db, sql: """
        SELECT id, day, logged_at, fluid_ml, display_name FROM diary_entry
        WHERE fluid_ml > 0 AND deleted_at IS NULL AND day >= ? AND day <= ?
        """, arguments: range) {
            // `logged_at` is ISO-8601 TEXT (see `Timestamp`); a row that doesn't parse can't be placed in the day.
            guard let at = (row["logged_at"] as String?).flatMap(Timestamp.date) else { continue }
            add(row["day"], FluidIntake(
                id: row["id"], ml: row["fluid_ml"], at: at, kind: .other, source: .diary, name: row["display_name"],
            ))
        }

        for entry in try CaffeineEntry
            .filter(CaffeineEntry.Columns.day >= days.lowerBound && CaffeineEntry.Columns.day <= days.upperBound)
            .filter(CaffeineEntry.Columns.deletedAt == nil && CaffeineEntry.Columns.ml > 0)
            .fetchAll(db)
        {
            guard let ml = entry.ml else { continue }
            let name = entry.name ?? entry.drinkID.flatMap(CaffeineDrink.preset(id:))?.name ?? Self.caffeineName
            add(entry.day, FluidIntake(id: entry.id, ml: ml, at: entry.loggedAt, kind: .other, source: .caffeine, name: name))
        }

        return result.mapValues { intakes in intakes.sorted { ($0.at, $0.id) < ($1.at, $1.id) } }
    }
}
