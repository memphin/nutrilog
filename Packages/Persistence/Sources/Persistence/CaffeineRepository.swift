import Core
import Foundation
import GRDB

/// A caffeine quick-add logged in Vitalion (`caffeine_entry`): a preset drink (``drinkID``, see Core
/// `CaffeineDrink`) or a custom amount. Caffeine from foods lives on diary entries instead (`diary_entry.caffeine_mg`,
/// see ``DiaryCaffeineIntake``).
public struct CaffeineEntry: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "caffeine_entry"

    public var id: String
    public var day: LocalDay
    /// When it was drunk — the dose time for the caffeine curve.
    public var loggedAt: Date
    public var mg: Double
    /// The preset drink's id (`CaffeineDrink.id`); nil for a custom amount.
    public var drinkID: String?
    /// Display name at log time (e.g. "Espresso"); nil when none was given.
    public var name: String?
    /// The drink's volume in ml: the preset's serving at log time, optional for a custom amount (nil when unknown).
    public var ml: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, mg, name, ml, revision
        case loggedAt = "logged_at"
        case drinkID = "drink_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    /// The entry as a dose for `CaffeineModel`.
    public var dose: CaffeineDose {
        CaffeineDose(mg: mg, at: loggedAt)
    }
}

/// Caffeine from a diary entry whose food states caffeine (`diary_entry.caffeine_mg > 0`). Read-only here: edit or
/// delete it through ``DiaryRepository``.
public struct DiaryCaffeineIntake: Hashable, Identifiable, Sendable {
    /// The diary entry's id.
    public var id: String
    public var day: LocalDay
    /// The entry's `logged_at`, taken as the time it was consumed.
    public var loggedAt: Date
    /// The entry's caffeine total in mg (the snapshot scaled to the logged amount).
    public var mg: Double
    /// The entry's display name (the food's name at log time).
    public var name: String

    public init(id: String, day: LocalDay, loggedAt: Date, mg: Double, name: String) {
        self.id = id
        self.day = day
        self.loggedAt = loggedAt
        self.mg = mg
        self.name = name
    }

    public var dose: CaffeineDose {
        CaffeineDose(mg: mg, at: loggedAt)
    }
}

/// All caffeine of a range of days from both sources, as one value for a single observation.
public struct CaffeineIntakes: Hashable, Sendable {
    /// Quick-add drinks, oldest first.
    public var quickAdds: [CaffeineEntry]
    /// Diary entries with caffeine, oldest first.
    public var diary: [DiaryCaffeineIntake]

    public init(quickAdds: [CaffeineEntry] = [], diary: [DiaryCaffeineIntake] = []) {
        self.quickAdds = quickAdds
        self.diary = diary
    }

    /// Every dose of both sources, oldest first — the input of `CaffeineModel`.
    public var doses: [CaffeineDose] {
        (quickAdds.map(\.dose) + diary.map(\.dose)).sorted { $0.at < $1.at }
    }

    /// Total caffeine in mg logged on `day` (both sources), e.g. against `CaffeineDefaults.dailyLimitMg`.
    public func totalMg(on day: LocalDay) -> Double {
        quickAdds.filter { $0.day == day }.reduce(0) { $0 + $1.mg } + diary.filter { $0.day == day }.reduce(0) { $0 + $1.mg }
    }
}

/// Caffeine quick-adds: add, edit, soft delete with undo, per-day and multi-day lists. Unlike water, nothing is written
/// to Apple Health. ``observeIntakes(in:)`` also brings the caffeine of diary entries, for the dashboard's curve.
public struct CaffeineRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Writes

    /// Logs `mg` of caffeine on `day`, drunk now (or at `loggedAt`). `drinkID` is the preset's id, `name` the label to
    /// show (blank names are stored as nil). `ml` is the drink's volume for hydration; without it a preset drink stores
    /// its serving (`CaffeineDrink.servingMl`) and a custom amount none.
    @discardableResult
    public func add(
        mg: Double, day: LocalDay, loggedAt: Date? = nil, drinkID: String? = nil, name: String? = nil, ml: Double? = nil,
    ) throws -> CaffeineEntry {
        try Self.validate(mg: mg)
        if let ml {
            guard ml > 0, ml.isFinite else { throw PersistenceError.amountNotPositive }
            try EntryLimits.validate(amount: ml)
        }
        let volume = ml ?? drinkID.flatMap(CaffeineDrink.preset(id:))?.servingMl
        let name = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.nonBlank
        let now = clock.now()
        return try database.writer.write { db in
            let entry = CaffeineEntry(
                id: newID(), day: day, loggedAt: loggedAt ?? now, mg: mg, drinkID: drinkID, name: name,
                ml: volume, createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            )
            try entry.insert(db)
            return entry
        }
    }

    /// Changes the amount and time of an active entry. Pass `day` when the new time falls on another calendar day
    /// (the repository doesn't know the user's calendar); otherwise the entry keeps its day.
    @discardableResult
    public func update(id: String, mg: Double, loggedAt: Date, day: LocalDay? = nil) throws -> CaffeineEntry {
        try Self.validate(mg: mg)
        let now = clock.now()
        return try database.writer.write { db in
            guard var entry = try CaffeineEntry.fetchOne(db, key: id), entry.deletedAt == nil else {
                throw PersistenceError.notFound(id)
            }
            entry.mg = mg
            entry.loggedAt = loggedAt
            if let day {
                entry.day = day
            }
            entry.stampUpdated(now)
            try entry.update(db)
            return entry
        }
    }

    public func softDelete(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in try CaffeineEntry.softDelete(db, ids: ids, now: now) }
    }

    /// Undo for `softDelete`.
    public func restore(ids: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in try CaffeineEntry.restore(db, ids: ids, now: now) }
    }

    // MARK: Reads

    /// The entry with `id`, deleted or not.
    public func entry(id: String) throws -> CaffeineEntry? {
        try database.reader.read { db in try CaffeineEntry.fetchOne(db, key: id) }
    }

    /// The day's active entries, oldest first.
    public func entries(for day: LocalDay) throws -> [CaffeineEntry] {
        try entries(in: day ... day)
    }

    /// Active entries of every day in `days`, oldest first.
    public func entries(in days: ClosedRange<LocalDay>) throws -> [CaffeineEntry] {
        try database.reader.read { db in try Self.entries(db, in: days) }
    }

    /// Active entries of every day in `days`, now and after every change.
    public func observeEntries(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<[CaffeineEntry]> {
        database.observe { db in try Self.entries(db, in: days) }
    }

    /// Quick-adds and diary caffeine of every day in `days`.
    public func intakes(in days: ClosedRange<LocalDay>) throws -> CaffeineIntakes {
        try database.reader.read { db in try Self.intakes(db, in: days) }
    }

    /// Quick-adds and diary caffeine of every day in `days`, now and after every change to either — one observation
    /// for the dashboard tile (current amount, sleep-safe time) and its detail chart. Include the day before today:
    /// caffeine from last night still counts this morning.
    public func observeIntakes(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<CaffeineIntakes> {
        database.observe { db in try Self.intakes(db, in: days) }
    }

    // MARK: Helpers

    static func entries(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [CaffeineEntry] {
        try CaffeineEntry
            .filter(CaffeineEntry.Columns.day >= days.lowerBound && CaffeineEntry.Columns.day <= days.upperBound)
            .filter(CaffeineEntry.Columns.deletedAt == nil)
            .order(CaffeineEntry.Columns.loggedAt, CaffeineEntry.Columns.id)
            .fetchAll(db)
    }

    static func intakes(_ db: Database, in days: ClosedRange<LocalDay>) throws -> CaffeineIntakes {
        try CaffeineIntakes(quickAdds: entries(db, in: days), diary: DiaryRepository.caffeineIntakes(db, in: days))
    }

    static func validate(mg: Double) throws {
        guard mg > 0, mg.isFinite else { throw PersistenceError.amountNotPositive }
    }
}
