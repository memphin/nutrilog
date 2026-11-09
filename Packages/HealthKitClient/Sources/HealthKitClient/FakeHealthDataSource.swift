import Core
import Foundation
import Synchronization

/// In-memory `HealthDataSource` for tests, SwiftUI previews and `-uiSampleData`.
///
/// Put raw samples in `State`; `fetchDailyData` buckets the cumulative ones into one statistic per local day,
/// like a daily statistics collection query (without Health's cross-source de-duplication, so don't add
/// overlapping cumulative samples from two sources). Setting `readAllowed = false` mimics a user who denied
/// every read type: everything comes back empty, exactly like the real opaque behaviour.
public final class FakeHealthDataSource: HealthDataSource {
    public struct State: Sendable {
        public var authorizationRequested = false
        /// False: every read comes back empty (read denial is indistinguishable from no data).
        public var readAllowed = true
        public var writeAllowed = true
        public var cumulativeSamples: [CumulativeMetric: [HealthQuantitySample]] = [:]
        public var samples: [SampledMetric: [HealthQuantitySample]] = [:]
        public var sleep: [SleepSample] = []
        public var characteristics = HealthCharacteristics()
        /// Thrown by the next `requestAuthorization()` / every `fetchDailyData` call while set.
        public var authorizationError: (any Error & Sendable)?
        public var fetchError: (any Error & Sendable)?
        // Recorded calls, for assertions.
        public var authorizationRequestCount = 0
        public var fetchedRanges: [ClosedRange<LocalDay>] = []

        public init() {}
    }

    public let isAvailable: Bool
    private let state: Mutex<State>

    public init(isAvailable: Bool = true, state: State = State()) {
        self.isAvailable = isAvailable
        self.state = Mutex(state)
    }

    /// The current state (a copy).
    public var snapshot: State {
        state.withLock { $0 }
    }

    /// Changes the state, e.g. to add samples between two syncs.
    public func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    // MARK: HealthDataSource

    public func authorizationRequestStatus() async -> HealthAuthorizationRequestStatus {
        guard isAvailable else { return .unknown }
        return snapshot.authorizationRequested ? .unnecessary : .shouldRequest
    }

    public func requestAuthorization() async throws {
        guard isAvailable else { throw HealthDataError.unavailable }
        try state.withLock { state in
            state.authorizationRequestCount += 1
            if let error = state.authorizationError {
                state.authorizationError = nil
                throw error
            }
            state.authorizationRequested = true
        }
    }

    public func writeAuthorization(for _: HealthWriteType) async -> HealthWriteAuthorization {
        let state = snapshot
        guard state.authorizationRequested else { return .notDetermined }
        return state.writeAllowed ? .authorized : .denied
    }

    public func fetchDailyData(for days: ClosedRange<LocalDay>, calendar: Calendar) async throws -> HealthDataBatch {
        guard isAvailable else { throw HealthDataError.unavailable }
        let state = state.withLock { state in
            state.fetchedRanges.append(days)
            return state
        }
        if let error = state.fetchError {
            throw error
        }
        guard state.readAllowed else { return HealthDataBatch(days: days) }

        let plan = HealthFetchPlan(days: days, calendar: calendar)
        let inDays = { (sample: HealthQuantitySample) in plan.dayInterval.contains(sample.start) && sample.start < plan.dayInterval.end }
        return HealthDataBatch(
            days: days,
            statistics: state.cumulativeSamples.mapValues { Self.dailyStatistics($0.filter(inDays), plan: plan) },
            samples: state.samples.mapValues { $0.filter(inDays) },
            sleep: state.sleep.filter { $0.end > plan.sleepInterval.start && $0.end <= plan.sleepInterval.end },
        )
    }

    public func fetchCharacteristics() async throws -> HealthCharacteristics {
        guard isAvailable else { throw HealthDataError.unavailable }
        let state = snapshot
        return state.readAllowed ? state.characteristics : HealthCharacteristics()
    }

    /// One statistic per local day that has samples, with per-source sums.
    static func dailyStatistics(_ samples: [HealthQuantitySample], plan: HealthFetchPlan) -> [CumulativeStatistic] {
        let byDay = Dictionary(grouping: samples) { plan.day(containing: $0.start) }
        return byDay.compactMap { day, samples -> CumulativeStatistic? in
            guard let day else { return nil }
            let interval = day.dateInterval(calendar: plan.calendar)
            let bySource = Dictionary(grouping: samples, by: \.source).map { source, samples in
                SourceContribution(source: source, sum: samples.reduce(0) { $0 + $1.value })
            }
            return CumulativeStatistic(
                start: interval.start,
                end: interval.end,
                sum: samples.reduce(0) { $0 + $1.value },
                sources: bySource.sorted { $0.source.name < $1.source.name },
            )
        }
        .sorted { $0.start < $1.start }
    }
}
