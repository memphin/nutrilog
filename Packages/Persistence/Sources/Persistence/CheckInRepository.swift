import Core
import Foundation
import GRDB

extension TDEEConfidence: @retroactive DatabaseValueConvertible {}

/// What the user did with a weekly check-in's proposal (SPEC §5.4.1 step 6).
public enum CheckInDecision: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// The proposed target was applied.
    case accepted
    /// The user applied a different target.
    case edited
    /// The target was left as it was.
    case skipped
}

/// One weekly check-in (`tdee_estimate`): the estimate, the proposal and the decision (backlog #35).
public struct CheckInRecord: Codable, Hashable, Identifiable, Sendable, TimestampedRecord {
    public static let databaseTableName = "tdee_estimate"

    public var id: String
    /// The day of the check-in (the estimate's window ends the day before).
    public var computedForDay: LocalDay
    public var windowDays: Int
    public var loggedDays: Int
    public var meanIntakeKcal: Double
    public var trendStartKg: Double
    public var trendEndKg: Double
    public var tdeeKcal: Double
    public var confidence: TDEEConfidence
    public var proposedTargetKcal: Double?
    public var decision: CheckInDecision?
    public var rawTDEEKcal: Double?
    public var baselineKcal: Double?
    /// Actual trend change per week at the time (negative = loss).
    public var weeklyChangeKg: Double?
    /// The goal at the time, signed (−0.5 = lose half a kilo a week).
    public var goalChangeKgPerWeek: Double?
    public var previousTargetKcal: Double?
    public var appliedTargetKcal: Double?
    /// The full `TDEEEstimate` as JSON, for the "how was this computed" sheet.
    public var detailsJSON: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, confidence, decision, revision
        case computedForDay = "computed_for_day"
        case windowDays = "window_days"
        case loggedDays = "logged_days"
        case meanIntakeKcal = "mean_intake_kcal"
        case trendStartKg = "trend_start_kg"
        case trendEndKg = "trend_end_kg"
        case tdeeKcal = "tdee_kcal"
        case proposedTargetKcal = "proposed_target_kcal"
        case rawTDEEKcal = "raw_tdee_kcal"
        case baselineKcal = "baseline_kcal"
        case weeklyChangeKg = "weekly_change_kg"
        case goalChangeKgPerWeek = "goal_change_kg_per_week"
        case previousTargetKcal = "previous_target_kcal"
        case appliedTargetKcal = "applied_target_kcal"
        case detailsJSON = "details_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public typealias Columns = CodingKeys

    /// The stored estimate with the days it used; nil for rows written without details.
    public var estimate: TDEEEstimate? {
        detailsJSON.flatMap { try? JSONDecoder().decode(TDEEEstimate.self, from: Data($0.utf8)) }
    }
}

/// Weekly check-ins: stores the estimate with the decision and, when a target was applied, the new target — in one
/// transaction — and reads the history.
public struct CheckInRepository: Sendable {
    let database: AppDatabase
    let clock: AppClock

    public init(_ database: AppDatabase, clock: AppClock = .system) {
        self.database = database
        self.clock = clock
    }

    /// Records the check-in of `checkInDay`. `appliedTarget` (required for accepted / edited, forbidden for skipped)
    /// is saved as the target from its `effectiveFrom`. A second check-in on the same day replaces the first.
    @discardableResult
    public func record(
        estimate: TDEEEstimate,
        checkInDay: LocalDay,
        proposedTargetKcal: Double,
        decision: CheckInDecision,
        appliedTarget: Target? = nil,
        previousTargetKcal: Double? = nil,
        goalChangeKgPerWeek: Double = 0,
    ) throws -> CheckInRecord {
        guard (decision == .skipped) == (appliedTarget == nil) else {
            throw PersistenceError.validation("accepted and edited check-ins need a target; skipped ones have none")
        }
        let now = clock.now()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let details = try String(decoding: encoder.encode(estimate), as: UTF8.self)
        return try database.writer.write { db in
            var record = CheckInRecord(
                id: newID(), computedForDay: checkInDay, windowDays: estimate.windowDays, loggedDays: estimate.loggedDays,
                meanIntakeKcal: estimate.meanIntakeKcal, trendStartKg: estimate.trendStartKg, trendEndKg: estimate.trendEndKg,
                tdeeKcal: estimate.kcal, confidence: estimate.confidence, proposedTargetKcal: proposedTargetKcal,
                decision: decision, rawTDEEKcal: estimate.rawKcal, baselineKcal: estimate.baselineKcal,
                weeklyChangeKg: estimate.weeklyChangeKg, goalChangeKgPerWeek: goalChangeKgPerWeek,
                previousTargetKcal: previousTargetKcal, appliedTargetKcal: appliedTarget?.kcal, detailsJSON: details,
                createdAt: now, updatedAt: now, revision: 1,
            )
            if let existing = try CheckInRecord.filter(CheckInRecord.Columns.computedForDay == checkInDay).fetchOne(db) {
                record.id = existing.id
                record.createdAt = existing.createdAt
                record.revision = existing.revision + 1
                try record.update(db)
            } else {
                try record.insert(db)
            }
            if let appliedTarget {
                _ = try ProfileRepository.setTarget(db, appliedTarget, now: now)
            }
            return record
        }
    }

    /// Past check-ins, newest first.
    public func history(limit: Int? = nil) throws -> [CheckInRecord] {
        try database.reader.read { db in
            var request = CheckInRecord.order(CheckInRecord.Columns.computedForDay.desc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func observeHistory() -> AsyncValueObservation<[CheckInRecord]> {
        ValueObservation
            .tracking { db in try CheckInRecord.order(CheckInRecord.Columns.computedForDay.desc).fetchAll(db) }
            .removeDuplicates()
            .values(in: database.reader)
    }

    /// The most recent check-in on or before `day` (default: any).
    public func latest(onOrBefore day: LocalDay? = nil) throws -> CheckInRecord? {
        try database.reader.read { db in
            var request = CheckInRecord.order(CheckInRecord.Columns.computedForDay.desc)
            if let day {
                request = request.filter(CheckInRecord.Columns.computedForDay <= day)
            }
            return try request.fetchOne(db)
        }
    }

    /// The estimate of the last check-in before `day` — the "previous week's estimate" a new one is blended with.
    public func previousEstimateKcal(before day: LocalDay) throws -> Double? {
        try database.reader.read { db in
            try CheckInRecord
                .filter(CheckInRecord.Columns.computedForDay < day)
                .order(CheckInRecord.Columns.computedForDay.desc)
                .fetchOne(db)?.tdeeKcal
        }
    }
}
