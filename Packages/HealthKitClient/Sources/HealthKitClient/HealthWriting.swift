import Core
import Foundation

/// Writing Nutrilog's own entries to Apple Health (backlog #27, FR-43, FR-46). A separate protocol next to
/// `HealthDataSource`: `LiveHealthDataSource` adopts both, tests use `FakeHealthWriter`.
///
/// Every sample carries the id of the Nutrilog row it mirrors (`HKMetadataKeyExternalUUID`) plus a sync identifier
/// "<row id>.<type>" and a sync version that grows with every edit and every retry (`syncVersion`). Deleting by
/// external id therefore removes everything written for a row, even when the `healthkit_link` rows were lost (e.g. the
/// app was killed between saving and storing the link), and a rewrite always outranks an older copy Health holds.
///
/// Loop prevention (SPEC §3.4): only rows the user entered in Nutrilog (diary and water entries, manual weights)
/// are ever turned into drafts. Values read from Health go to `daily_metrics` and never reach a writer.
public protocol HealthWriting: Sendable {
    /// False on devices without a Health store.
    var isAvailable: Bool { get }

    /// Write permission for `type` (Health reports it truthfully, unlike read permission).
    func writeAuthorization(for type: HealthWriteType) async -> HealthWriteAuthorization

    /// Saves the samples and returns the UUID HealthKit assigned to each, in order. All or nothing.
    func save(_ samples: [HealthSampleDraft]) async throws -> [UUID]

    /// Deletes every sample of `types` that this app wrote for the row `externalID`. Samples written by other apps
    /// are never touched (HealthKit only lets an app delete its own). Returns the number deleted; nothing matching
    /// is 0, never an error.
    @discardableResult
    func deleteSamples(externalID: String, types: Set<HealthWriteType>) async throws -> Int
}

/// One sample to write, in the type's canonical unit (`HealthWriteType.unitSymbol`).
public struct HealthSampleDraft: Hashable, Sendable {
    public var type: HealthWriteType
    public var value: Double
    /// Start and end of the (instantaneous) sample.
    public var date: Date
    /// The Nutrilog row id (`diary_entry.id`, `water_entry.id`) → `HKMetadataKeyExternalUUID`.
    public var externalID: String
    /// → `HKMetadataKeySyncVersion`; see `HealthSamples.syncVersion(revision:attempt:)`.
    public var version: Int

    public init(type: HealthWriteType, value: Double, date: Date, externalID: String, version: Int) {
        self.type = type
        self.value = value
        self.date = date
        self.externalID = externalID
        self.version = version
    }

    /// `HKMetadataKeySyncIdentifier`: one per row and type.
    public var syncIdentifier: String {
        "\(externalID).\(type.rawValue)"
    }
}

public extension HealthWriteType {
    /// The types written for a diary entry.
    static let dietaryNutrients: Set<HealthWriteType> = [
        .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber,
        .dietarySugar, .dietarySodium,
    ]

    /// The types written for a manual weight.
    static let body: Set<HealthWriteType> = [.bodyMass, .bodyFatPercentage]

    /// Unit of `HealthSampleDraft.value`.
    var unitSymbol: String {
        switch self {
        case .dietaryEnergyConsumed: "kcal"
        case .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber, .dietarySugar: "g"
        case .dietarySodium: "mg"
        case .dietaryWater: "ml"
        case .bodyMass: "kg"
        case .bodyFatPercentage: "%"
        }
    }
}

/// Builds the drafts for Nutrilog rows.
public enum HealthSamples {
    /// The sync version of a write: `revision * 1000 + attempt`. It grows with every edit (revision) and every retry
    /// of the same revision (attempt), so a re-save after a crash or a failed try never carries the same version as a
    /// copy Health may already hold (HealthKit ignores or rejects a sync identifier saved again with an equal version).
    public static func syncVersion(revision: Int, attempt: Int) -> Int {
        revision * 1000 + min(max(attempt, 0), 999)
    }

    /// The nutrient samples of a diary entry. Missing (nil) and zero values are not written: Health sums
    /// dietary samples, so a 0 g sample adds nothing but noise.
    public static func dietary(
        _ nutrients: Nutrients, date: Date, externalID: String, version: Int,
    ) -> [HealthSampleDraft] {
        let values: [(HealthWriteType, Double?)] = [
            (.dietaryEnergyConsumed, nutrients.kcal),
            (.dietaryProtein, nutrients.proteinG),
            (.dietaryCarbohydrates, nutrients.carbsG),
            (.dietaryFatTotal, nutrients.fatG),
            (.dietaryFiber, nutrients.fiberG),
            (.dietarySugar, nutrients.sugarG),
            (.dietarySodium, nutrients.sodiumMg),
        ]
        return values.compactMap { type, value in
            guard let value, value > 0, value.isFinite else { return nil }
            return HealthSampleDraft(type: type, value: value, date: date, externalID: externalID, version: version)
        }
    }

    /// The water sample of a water entry.
    public static func water(ml: Double, date: Date, externalID: String, version: Int) -> [HealthSampleDraft] {
        guard ml > 0, ml.isFinite else { return [] }
        return [HealthSampleDraft(type: .dietaryWater, value: ml, date: date, externalID: externalID, version: version)]
    }

    /// The samples of a manual weight: body mass, plus body fat (in percent, 18.5) when entered.
    public static func weight(
        kg: Double, bodyFatPct: Double?, date: Date, externalID: String, version: Int,
    ) -> [HealthSampleDraft] {
        guard kg > 0, kg.isFinite else { return [] }
        var drafts = [HealthSampleDraft(type: .bodyMass, value: kg, date: date, externalID: externalID, version: version)]
        if let bodyFatPct, bodyFatPct > 0, bodyFatPct.isFinite {
            drafts.append(HealthSampleDraft(
                type: .bodyFatPercentage, value: bodyFatPct, date: date, externalID: externalID, version: version,
            ))
        }
        return drafts
    }

    /// When to date a sample for a row of local day `day` that was logged at `loggedAt`: the log time when it lies on
    /// that day (the usual case), otherwise `fallbackHour`:00 of the day (an entry logged for yesterday, or moved to
    /// another day), so Health files it under the same day as the diary.
    public static func date(
        day: LocalDay, loggedAt: Date, fallbackHour: Int? = nil, calendar: Calendar = .current,
    ) -> Date {
        if LocalDay(loggedAt, calendar: calendar) == day {
            return loggedAt
        }
        let hour = min(max(fallbackHour ?? 12, 0), 23)
        return day.date(atHour: hour, calendar: calendar)
    }
}
