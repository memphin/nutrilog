import Core
import Foundation

/// Read access to Apple Health (backlog #23, #24). The app and its tests depend on this protocol only:
/// `LiveHealthDataSource` talks to HealthKit on iOS, `FakeHealthDataSource` serves canned data.
///
/// Health never tells an app whether *read* access was denied — a denied type simply returns no data. Callers
/// must therefore treat "no data" as "no data found — check Health permissions" (`HealthKitClient.noDataMessage`),
/// never as a confirmed denial.
///
/// Later backlog items extend the client with separate protocols that a source can adopt alongside this one:
/// observer queries and background delivery (#26), and writing nutrients, water and weight (#27, using
/// `HealthWriteType` and `healthkit_link`).
public protocol HealthDataSource: Sendable {
    /// False on devices without a Health store (some iPads); hide Health features there.
    var isAvailable: Bool { get }

    /// Whether `requestAuthorization()` would show the permission sheet. `.unnecessary` only means the user has
    /// answered for every type; it says nothing about which read types they allowed.
    func authorizationRequestStatus() async -> HealthAuthorizationRequestStatus

    /// Shows the system permission sheet for every `HealthReadType` and `HealthWriteType`, and returns once the
    /// user has answered. Success does not mean any read type was allowed. Show the onboarding explanation first.
    func requestAuthorization() async throws

    /// Write permission for `type`. Unlike read access, Health reports this truthfully.
    func writeAuthorization(for type: HealthWriteType) async -> HealthWriteAuthorization

    /// Raw Health data for the daily metrics of `days`, with day boundaries in `calendar`
    /// (see `HealthFetchPlan`). Reduce it with `DailyMetricsAggregator`. Denied types come back empty.
    func fetchDailyData(for days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> HealthDataBatch

    /// Profile characteristics for the calorie formula; fields are nil when missing or not shared.
    func fetchCharacteristics() async throws -> HealthCharacteristics
}

public enum HealthAuthorizationRequestStatus: Sendable, Equatable {
    /// Some types have never been asked for: show onboarding, then the permission sheet.
    case shouldRequest
    /// The user has answered for every type (allowed or not — reads are opaque).
    case unnecessary
    /// Health could not tell (no Health store, missing entitlement, error).
    case unknown
}

public enum HealthWriteAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// Profile values from Health (FR-30).
public struct HealthCharacteristics: Hashable, Sendable {
    public var heightCm: Double?
    public var dateOfBirth: LocalDay?
    public var sex: Sex?

    public init(heightCm: Double? = nil, dateOfBirth: LocalDay? = nil, sex: Sex? = nil) {
        self.heightCm = heightCm
        self.dateOfBirth = dateOfBirth
        self.sex = sex
    }

    /// Whether Health returned a value for a characteristic read type (nil for other types).
    public func hasValue(for type: HealthReadType) -> Bool? {
        switch type {
        case .height: heightCm != nil
        case .dateOfBirth: dateOfBirth != nil
        case .biologicalSex: sex != nil
        default: nil
        }
    }
}

public enum HealthDataError: Error, Equatable, Sendable {
    /// This device has no Health store.
    case unavailable
}

public extension HealthFetchPlan {
    /// The end-date range to query sleep samples with HealthKit's `.strictEndDate`, which is half-open
    /// [start, end). It runs one second past `sleepInterval.end` so a sample ending exactly at 18:00 on the last
    /// day is not lost (on a backfill chunk boundary it would be lost for good: the next chunk does not own that
    /// night). Samples outside the nights are dropped by `SleepAggregator`.
    var sleepQueryInterval: DateInterval {
        DateInterval(start: sleepInterval.start, end: sleepInterval.end.addingTimeInterval(1))
    }
}

/// Shared texts and constants of the Health integration.
public enum HealthKitClient {
    /// Shown wherever a Health value is missing: read access is opaque, so missing data may mean a denied type.
    public static let noDataMessage = "No data found — check Health permissions"

    /// Where the user changes Health permissions for the app.
    public static let permissionsPath = "Settings › Health › Data Access & Devices › Nutrilog"
}
