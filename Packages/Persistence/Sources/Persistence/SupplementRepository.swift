import Core
import Foundation
import GRDB

/// A row of `supplement`: a supplement or medication the user takes, with its schedule (Core `SupplementSchedule`).
public struct Supplement: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "supplement"

    public var id: String
    public var name: String
    /// Free text, e.g. "1 tablet" or "500 mg"; empty when not given.
    public var dose: String
    public var note: String?
    /// Sorted minutes after midnight as a JSON array, e.g. "[480,1260]"; "[]" = as needed.
    public var timesJSON: String
    /// `Calendar.weekday` numbers as a JSON array; "[]" = every day.
    public var weekdaysJSON: String
    /// No doses are due before this day (the day it was added).
    public var startDay: LocalDay
    public var remindersEnabled: Bool
    /// Switched off: no doses are due and nothing is reminded, but the doses logged so far stay.
    public var isActive: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name, dose, note, revision
        case timesJSON = "times_json"
        case weekdaysJSON = "weekdays_json"
        case startDay = "start_day"
        case remindersEnabled = "reminders_enabled"
        case isActive = "is_active"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(
        id: String = newID(), name: String, dose: String = "", note: String? = nil, schedule: SupplementSchedule,
        startDay: LocalDay, remindersEnabled: Bool = true, isActive: Bool = true, sortOrder: Int = 0,
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.note = note
        timesJSON = Self.json(schedule.times)
        weekdaysJSON = Self.json(schedule.weekdays.sorted())
        self.startDay = startDay
        self.remindersEnabled = remindersEnabled
        self.isActive = isActive
        self.sortOrder = sortOrder
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }

    /// The schedule; unreadable values count as as-needed and every day.
    public var schedule: SupplementSchedule {
        get {
            SupplementSchedule(times: Self.decode(timesJSON), weekdays: Set(Self.decode(weekdaysJSON)))
        }
        set {
            timesJSON = Self.json(newValue.times)
            weekdaysJSON = Self.json(newValue.weekdays.sorted())
        }
    }

    /// "Vitamin D3 · 2000 IU", or the name alone without a dose.
    public var displayName: String {
        dose.isEmpty ? name : "\(name) · \(dose)"
    }

    /// The supplement as the reminder planner sees it.
    public var reminderItem: SupplementReminderPlanner.Item {
        .init(id: id, name: name, dose: dose, schedule: schedule, startDay: startDay)
    }

    /// Whether doses are due on `day`: active, started, and scheduled on its weekday.
    public func times(on day: LocalDay) -> [Int] {
        isActive && day >= startDay ? schedule.times(on: day) : []
    }

    static func json(_ numbers: [Int]) -> String {
        "[" + numbers.map(String.init).joined(separator: ",") + "]"
    }

    static func decode(_ json: String) -> [Int] {
        (try? JSONDecoder().decode([Int].self, from: Data(json.utf8))) ?? []
    }
}

/// A row of `supplement_dose`: a dose taken or skipped. A scheduled dose has its `scheduledMinute`; an extra dose
/// (as needed, or one more than scheduled) has none.
public struct SupplementDose: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "supplement_dose"

    public enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case taken, skipped
    }

    public var id: String
    public var supplementID: String
    public var day: LocalDay
    public var scheduledMinute: Int?
    public var status: Status
    /// When it was taken; nil when skipped.
    public var takenAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, status, revision
        case supplementID = "supplement_id"
        case scheduledMinute = "scheduled_minute"
        case takenAt = "taken_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    /// The scheduled dose this row answers; nil for an extra dose.
    public var key: SupplementDoseKey? {
        scheduledMinute.map { SupplementDoseKey(supplementID: supplementID, slot: SupplementSlot(day: day, minute: $0)) }
    }
}

/// A day's supplements as the diary shows them: the doses due that day, each with what was logged for it, then the
/// extra doses.
public struct SupplementDay: Equatable, Sendable {
    public var day: LocalDay
    /// Every supplement, switched-off ones included, in the user's order.
    public var supplements: [Supplement]
    /// The day's logged doses.
    public var doses: [SupplementDose]

    public init(day: LocalDay, supplements: [Supplement], doses: [SupplementDose]) {
        self.day = day
        self.supplements = supplements
        self.doses = doses
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public var day: LocalDay
        public var supplement: Supplement
        /// The scheduled time; nil for an extra dose.
        public var minute: Int?
        /// What was logged; nil while a scheduled dose is open.
        public var dose: SupplementDose?

        public var id: String {
            if let minute {
                return "\(supplement.id)@\(minute)"
            }
            return dose?.id ?? supplement.id
        }

        public var key: SupplementDoseKey? {
            minute.map { SupplementDoseKey(supplementID: supplement.id, slot: SupplementSlot(day: day, minute: $0)) }
        }

        public var isTaken: Bool {
            dose?.status == .taken
        }

        public var isSkipped: Bool {
            dose?.status == .skipped
        }
    }

    /// The scheduled doses in time order (the user's order within a time), including logged doses whose time is no
    /// longer in the schedule, then the extra doses in the order they were taken.
    public var rows: [Row] {
        let byID = Dictionary(supplements.map { ($0.id, $0) }) { first, _ in first }
        var logged: [SupplementDoseKey: SupplementDose] = [:]
        for dose in doses {
            if let key = dose.key {
                logged[key] = dose
            }
        }
        var scheduled: [Row] = []
        var seen: Set<SupplementDoseKey> = []
        for supplement in supplements {
            for minute in supplement.times(on: day) {
                let key = SupplementDoseKey(supplementID: supplement.id, slot: SupplementSlot(day: day, minute: minute))
                seen.insert(key)
                scheduled.append(Row(day: day, supplement: supplement, minute: minute, dose: logged[key]))
            }
        }
        for (key, dose) in logged where !seen.contains(key) {
            guard let supplement = byID[key.supplementID] else { continue }
            scheduled.append(Row(day: day, supplement: supplement, minute: key.slot.minute, dose: dose))
        }
        scheduled.sort {
            ($0.minute ?? 0, $0.supplement.sortOrder, $0.supplement.id) < ($1.minute ?? 0, $1.supplement.sortOrder, $1.supplement.id)
        }
        let extras = doses
            .filter { $0.scheduledMinute == nil }
            .sorted { ($0.takenAt ?? $0.createdAt, $0.id) < ($1.takenAt ?? $1.createdAt, $1.id) }
            .compactMap { dose in byID[dose.supplementID].map { Row(day: day, supplement: $0, minute: nil, dose: dose) } }
        return scheduled + extras
    }

    /// Scheduled doses taken, and scheduled doses in all (logged ones off the schedule included).
    public var progress: (taken: Int, total: Int) {
        let scheduled = rows.filter { $0.minute != nil }
        return (scheduled.count(where: \.isTaken), scheduled.count)
    }

    /// The active supplements, for logging an extra dose.
    public var active: [Supplement] {
        supplements.filter(\.isActive)
    }
}

/// What the reminders are planned from: the supplements reminded of and the doses already handled.
public struct SupplementReminderInput: Equatable, Sendable {
    public var items: [SupplementReminderPlanner.Item]
    public var handled: Set<SupplementDoseKey>

    public init(items: [SupplementReminderPlanner.Item], handled: Set<SupplementDoseKey>) {
        self.items = items
        self.handled = handled
    }
}

/// Supplements and medications (`supplement`) and the doses taken or skipped (`supplement_dose`).
public struct SupplementRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: Supplements

    public func supplements(includeInactive: Bool = true) throws -> [Supplement] {
        try database.reader.read { db in try Self.supplements(db, includeInactive: includeInactive) }
    }

    public func observeSupplements() -> AsyncValueObservation<[Supplement]> {
        database.observe { db in try Self.supplements(db, includeInactive: true) }
    }

    public func supplement(id: String) throws -> Supplement? {
        try database.reader.read { db in try Supplement.filter(key: id).filter(Supplement.Columns.deletedAt == nil).fetchOne(db) }
    }

    /// Adds `supplement` (last in the list) or saves the changes to an existing one. The name is trimmed and must not
    /// be empty; the dose and note are trimmed, an empty note stored as none.
    @discardableResult
    public func save(_ supplement: Supplement) throws -> Supplement {
        var record = supplement
        record.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.dose = record.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        record.note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.note?.isEmpty == true {
            record.note = nil
        }
        guard !record.name.isEmpty else {
            throw PersistenceError.validation(String(localized: "name must not be empty", bundle: .module))
        }
        let now = clock.now()
        return try database.writer.write { db in
            if var existing = try Supplement.fetchOne(db, key: record.id), existing.deletedAt == nil {
                record.createdAt = existing.createdAt
                record.revision = existing.revision
                record.updatedAt = existing.updatedAt
                record.deletedAt = nil
                guard record != existing else { return existing }
                existing = record
                existing.stampUpdated(now)
                try existing.update(db)
                return existing
            }
            let last = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM supplement WHERE deleted_at IS NULL") ?? -1
            record.sortOrder = last + 1
            record.stampCreated(now)
            try record.insert(db)
            return record
        }
    }

    /// Deletes the supplement; its logged doses are kept but no longer shown.
    public func delete(id: String) throws {
        let now = clock.now()
        try database.writer.write { db in _ = try Supplement.softDelete(db, ids: [id], now: now) }
    }

    /// Puts the supplements in the order of `orderedIDs`.
    public func reorder(_ orderedIDs: [String]) throws {
        let now = clock.now()
        try database.writer.write { db in
            for (index, id) in orderedIDs.enumerated() {
                guard var record = try Supplement.fetchOne(db, key: id), record.sortOrder != index else { continue }
                record.sortOrder = index
                record.stampUpdated(now)
                try record.update(db)
            }
        }
    }

    // MARK: Days

    public func day(_ day: LocalDay) throws -> SupplementDay {
        try database.reader.read { db in try Self.day(db, day) }
    }

    /// ``day(_:)`` now and after every change, for the diary.
    public func observeDay(_ day: LocalDay) -> AsyncValueObservation<SupplementDay> {
        database.observe { db in try Self.day(db, day) }
    }

    // MARK: Doses

    /// Marks the scheduled doses `keys` as taken at `at` (each replaces what was logged for it).
    public func markTaken(_ keys: [SupplementDoseKey], at: Date) throws {
        try log(keys, status: .taken, at: at)
    }

    /// Marks the scheduled doses `keys` as skipped.
    public func markSkipped(_ keys: [SupplementDoseKey]) throws {
        try log(keys, status: .skipped, at: nil)
    }

    /// Clears what was logged for the scheduled dose `key`: it is open again.
    public func clear(_ key: SupplementDoseKey) throws {
        let now = clock.now()
        try database.writer.write { db in
            if let id = try Self.liveDose(db, key)?.id {
                _ = try SupplementDose.softDelete(db, ids: [id], now: now)
            }
        }
    }

    /// Logs an extra dose of `supplementID` taken at `at` on `day`.
    @discardableResult
    public func logExtra(supplementID: String, day: LocalDay, at: Date) throws -> SupplementDose {
        let now = clock.now()
        return try database.writer.write { db in
            guard let supplement = try Supplement.fetchOne(db, key: supplementID), supplement.deletedAt == nil else {
                throw PersistenceError.notFound(supplementID)
            }
            var dose = SupplementDose(
                id: newID(), supplementID: supplementID, day: day, scheduledMinute: nil, status: .taken, takenAt: at,
                createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
            )
            dose.stampCreated(now)
            try dose.insert(db)
            return dose
        }
    }

    /// Changes when the logged dose `id` was taken.
    public func setTakenAt(doseID: String, _ at: Date) throws {
        let now = clock.now()
        try database.writer.write { db in
            guard var dose = try SupplementDose.fetchOne(db, key: doseID), dose.deletedAt == nil else {
                throw PersistenceError.notFound(doseID)
            }
            dose.status = .taken
            dose.takenAt = at
            dose.stampUpdated(now)
            try dose.update(db)
        }
    }

    /// Deletes the logged dose `id` (an extra dose; a scheduled one is open again).
    public func deleteDose(id: String) throws {
        let now = clock.now()
        try database.writer.write { db in _ = try SupplementDose.softDelete(db, ids: [id], now: now) }
    }

    // MARK: Reminders

    /// The supplements to remind of and the doses handled in `days`.
    public func reminderInput(in days: ClosedRange<LocalDay>) throws -> SupplementReminderInput {
        try database.reader.read { db in try Self.reminderInput(db, in: days) }
    }

    public func observeReminderInput(in days: ClosedRange<LocalDay>) -> AsyncValueObservation<SupplementReminderInput> {
        database.observe { db in try Self.reminderInput(db, in: days) }
    }

    // MARK: Helpers

    static func supplements(_ db: Database, includeInactive: Bool) throws -> [Supplement] {
        var request = Supplement.filter(Supplement.Columns.deletedAt == nil)
        if !includeInactive {
            request = request.filter(Supplement.Columns.isActive == true)
        }
        return try request.order(Supplement.Columns.sortOrder, Supplement.Columns.name).fetchAll(db)
    }

    static func doses(_ db: Database, in days: ClosedRange<LocalDay>) throws -> [SupplementDose] {
        try SupplementDose
            .filter(SupplementDose.Columns.day >= days.lowerBound && SupplementDose.Columns.day <= days.upperBound)
            .filter(SupplementDose.Columns.deletedAt == nil)
            .order(SupplementDose.Columns.day, SupplementDose.Columns.id)
            .fetchAll(db)
    }

    static func day(_ db: Database, _ day: LocalDay) throws -> SupplementDay {
        try SupplementDay(day: day, supplements: supplements(db, includeInactive: true), doses: doses(db, in: day ... day))
    }

    static func reminderInput(_ db: Database, in days: ClosedRange<LocalDay>) throws -> SupplementReminderInput {
        let items = try supplements(db, includeInactive: false)
            .filter { $0.remindersEnabled && !$0.schedule.isAsNeeded }
            .map(\.reminderItem)
        let handled = try Set(doses(db, in: days).compactMap(\.key))
        return SupplementReminderInput(items: items, handled: handled)
    }

    static func liveDose(_ db: Database, _ key: SupplementDoseKey) throws -> SupplementDose? {
        try SupplementDose
            .filter(SupplementDose.Columns.supplementID == key.supplementID)
            .filter(SupplementDose.Columns.day == key.slot.day)
            .filter(SupplementDose.Columns.scheduledMinute == key.slot.minute)
            .filter(SupplementDose.Columns.deletedAt == nil)
            .fetchOne(db)
    }

    private func log(_ keys: [SupplementDoseKey], status: SupplementDose.Status, at: Date?) throws {
        let now = clock.now()
        try database.writer.write { db in
            for key in keys {
                guard try Supplement.fetchOne(db, key: key.supplementID) != nil else {
                    throw PersistenceError.notFound(key.supplementID)
                }
                if var dose = try Self.liveDose(db, key) {
                    guard dose.status != status || dose.takenAt != at else { continue }
                    dose.status = status
                    dose.takenAt = at
                    dose.stampUpdated(now)
                    try dose.update(db)
                } else {
                    var dose = SupplementDose(
                        id: newID(), supplementID: key.supplementID, day: key.slot.day, scheduledMinute: key.slot.minute,
                        status: status, takenAt: at, createdAt: now, updatedAt: now, deletedAt: nil, revision: 1,
                    )
                    dose.stampCreated(now)
                    try dose.insert(db)
                }
            }
        }
    }
}
