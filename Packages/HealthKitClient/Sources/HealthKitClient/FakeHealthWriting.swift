import Core
import Foundation
import Synchronization

/// In-memory `HealthWriting` for tests and previews. Keeps the samples "in Health" and records every call.
///
/// With `mirror`, saved water, weight and body fat samples also appear in that fake's data under `source` (and
/// vanish when deleted), like the real store: a test can then check that what Vitalion wrote is not read back as data
/// from other apps.
public final class FakeHealthWriter: HealthWriting {
    public struct StoredSample: Hashable, Sendable {
        public var uuid: UUID
        public var draft: HealthSampleDraft
    }

    public struct State: Sendable {
        /// Samples currently "in Health", oldest first.
        public var samples: [StoredSample] = []
        /// Write permission per type; types not listed are authorized.
        public var authorization: [HealthWriteType: HealthWriteAuthorization] = [:]
        /// Thrown by `save` / `deleteSamples` while set.
        public var saveError: (any Error & Sendable)?
        public var deleteError: (any Error & Sendable)?
        /// Awaited at the start of every `save` — lets a test hold a write in flight.
        public var beforeSave: (@Sendable () async -> Void)?
        // Recorded calls, for assertions.
        public var saveCalls: [[HealthSampleDraft]] = []
        public var deleteCalls: [(externalID: String, types: Set<HealthWriteType>)] = []

        public init() {}

        /// The samples written for one row.
        public func samples(for externalID: String) -> [HealthSampleDraft] {
            samples.filter { $0.draft.externalID == externalID }.map(\.draft)
        }
    }

    public let isAvailable: Bool
    private let state: Mutex<State>
    private let mirror: FakeHealthDataSource?
    private let source: HealthSource

    public init(
        isAvailable: Bool = true,
        state: State = State(),
        mirror: FakeHealthDataSource? = nil,
        source: HealthSource = HealthSource(name: "Vitalion", bundleIdentifier: "hr.ivanjuric.nutrilog"),
    ) {
        self.isAvailable = isAvailable
        self.state = Mutex(state)
        self.mirror = mirror
        self.source = source
    }

    public var snapshot: State {
        state.withLock { $0 }
    }

    public func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    public func writeAuthorization(for type: HealthWriteType) async -> HealthWriteAuthorization {
        snapshot.authorization[type] ?? .authorized
    }

    public func save(_ drafts: [HealthSampleDraft]) async throws -> [UUID] {
        guard isAvailable else { throw HealthDataError.unavailable }
        if let beforeSave = snapshot.beforeSave {
            await beforeSave()
        }
        let stored = try state.withLock { state in
            state.saveCalls.append(drafts)
            if let error = state.saveError {
                throw error
            }
            if let denied = drafts.first(where: { (state.authorization[$0.type] ?? .authorized) != .authorized }) {
                throw FakeHealthWriterError.notAuthorized(denied.type)
            }
            let stored = drafts.map { StoredSample(uuid: UUID(), draft: $0) }
            state.samples += stored
            return stored
        }
        for sample in stored {
            let value = mirrored(sample.draft)
            mirror?.update { state in
                if sample.draft.type == .dietaryWater {
                    state.cumulativeSamples[.dietaryWater, default: []].append(value)
                } else if let metric = Self.sampledMetric(sample.draft.type) {
                    state.samples[metric, default: []].append(value)
                }
            }
        }
        return stored.map(\.uuid)
    }

    @discardableResult
    public func deleteSamples(externalID: String, types: Set<HealthWriteType>) async throws -> Int {
        guard isAvailable else { throw HealthDataError.unavailable }
        let removed = try state.withLock { state in
            state.deleteCalls.append((externalID, types))
            if let error = state.deleteError {
                throw error
            }
            if let denied = types.first(where: { (state.authorization[$0] ?? .authorized) != .authorized }) {
                throw FakeHealthWriterError.notAuthorized(denied)
            }
            let removed = state.samples.filter { $0.draft.externalID == externalID && types.contains($0.draft.type) }
            state.samples.removeAll { $0.draft.externalID == externalID && types.contains($0.draft.type) }
            return removed
        }
        for sample in removed {
            let value = mirrored(sample.draft)
            mirror?.update { state in
                if sample.draft.type == .dietaryWater {
                    if let index = state.cumulativeSamples[.dietaryWater]?.firstIndex(of: value) {
                        state.cumulativeSamples[.dietaryWater]?.remove(at: index)
                    }
                } else if let metric = Self.sampledMetric(sample.draft.type),
                          let index = state.samples[metric]?.firstIndex(of: value)
                {
                    state.samples[metric]?.remove(at: index)
                }
            }
        }
        return removed.count
    }

    private static func sampledMetric(_ type: HealthWriteType) -> SampledMetric? {
        switch type {
        case .bodyMass: .bodyMass
        case .bodyFatPercentage: .bodyFatPercentage
        default: nil
        }
    }

    private func mirrored(_ draft: HealthSampleDraft) -> HealthQuantitySample {
        HealthQuantitySample(start: draft.date, value: draft.value, source: source, externalID: draft.externalID)
    }
}

public enum FakeHealthWriterError: Error, Equatable, Sendable {
    case notAuthorized(HealthWriteType)
}

/// In-memory `HealthObserving` for tests. `fire(_:)` plays HealthKit: it delivers an update and returns the
/// completion, so a test can prove the completion handler was called.
public final class FakeHealthObserver: HealthObserving {
    public struct State: Sendable {
        /// The types of the running observer queries (empty when stopped).
        public var observedTypes: [HealthReadType] = []
        /// Types with background delivery enabled (stays after `stopObserving`, like HealthKit).
        public var backgroundDeliveryTypes: Set<HealthReadType> = []
        /// Types whose background delivery fails to enable.
        public var failingBackgroundDelivery: Set<HealthReadType> = []
        public var startCount = 0

        public init() {}
    }

    private let state: Mutex<State>
    private let handler = Mutex<(@Sendable (HealthObserverUpdate) -> Void)?>(nil)

    public init(state: State = State()) {
        self.state = Mutex(state)
    }

    public var snapshot: State {
        state.withLock { $0 }
    }

    public func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    public var isObserving: Bool {
        handler.withLock { $0 != nil }
    }

    public func startObserving(
        _ types: [HealthReadType], onUpdate: @escaping @Sendable (HealthObserverUpdate) -> Void,
    ) async throws {
        let observable = types.filter { $0.kind != .characteristic }
        handler.withLock { $0 = onUpdate }
        let failed = state.withLock { state in
            state.startCount += 1
            state.observedTypes = observable
            let failed = observable.filter { state.failingBackgroundDelivery.contains($0) }
            state.backgroundDeliveryTypes.formUnion(observable.filter { !failed.contains($0) })
            return failed
        }
        if !failed.isEmpty {
            throw HealthObserverError.backgroundDeliveryFailed(failed)
        }
    }

    public func stopObserving() async {
        handler.withLock { $0 = nil }
        state.withLock { $0.observedTypes = [] }
    }

    /// Delivers an update for `type` (with `error`, like a failed observer query) to the registered handler and
    /// returns its completion. Returns nil when the type is not observed — HealthKit would not call back.
    @discardableResult
    public func fire(_ type: HealthReadType, error: (any Error)? = nil) -> HealthObserverCompletion? {
        guard snapshot.observedTypes.contains(type), let handler = handler.withLock({ $0 }) else { return nil }
        let completion = HealthObserverCompletion {}
        handler(HealthObserverUpdate(type: type, error: error, completion: completion))
        return completion
    }
}
