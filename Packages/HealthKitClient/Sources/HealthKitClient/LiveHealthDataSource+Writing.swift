#if os(iOS)
    import Core
    import Foundation
    import HealthKit

    // MARK: - Writing (backlog #27)

    extension LiveHealthDataSource: HealthWriting {
        public func save(_ drafts: [HealthSampleDraft]) async throws -> [UUID] {
            guard isAvailable else { throw HealthDataError.unavailable }
            guard !drafts.isEmpty else { return [] }
            let samples = drafts.map { draft in
                HKQuantitySample(
                    type: draft.type.quantityType,
                    quantity: HKQuantity(unit: draft.type.unit, doubleValue: draft.value),
                    start: draft.date,
                    end: draft.date,
                    metadata: [
                        HKMetadataKeyExternalUUID: draft.externalID,
                        HKMetadataKeySyncIdentifier: draft.syncIdentifier,
                        HKMetadataKeySyncVersion: NSNumber(value: draft.version),
                        HKMetadataKeyWasUserEntered: true,
                    ],
                )
            }
            try await store.save(samples)
            return samples.map(\.uuid)
        }

        @discardableResult
        public func deleteSamples(externalID: String, types: Set<HealthWriteType>) async throws -> Int {
            guard isAvailable else { throw HealthDataError.unavailable }
            // Own samples only: HealthKit refuses to delete another source's samples, and the predicate also limits
            // the match to this app's source so a foreign sample with the same external id is never touched.
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [externalID]),
                HKQuery.predicateForObjects(from: HKSource.default()),
            ])
            var deleted = 0
            for type in types.sorted(by: { $0.rawValue < $1.rawValue }) {
                do {
                    deleted += try await store.deleteObjects(of: type.quantityType, predicate: predicate)
                } catch let error as HKError where error.code == .errorNoData {
                    // Nothing matched: that is "0 deleted", not a failure (verify the exact behaviour on device).
                }
            }
            return deleted
        }
    }

    // MARK: - Observer queries (backlog #26)

    extension LiveHealthDataSource: HealthObserving {
        public func startObserving(
            _ types: [HealthReadType], onUpdate: @escaping @Sendable (HealthObserverUpdate) -> Void,
        ) async throws {
            guard isAvailable else { throw HealthDataError.unavailable }
            await stopObserving()
            var queries: [HKObserverQuery] = []
            var failed: [HealthReadType] = []
            for type in types {
                guard let sampleType = type.objectType as? HKSampleType else { continue } // characteristics
                let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                    // HealthKit's handler is not annotated @Sendable; it may be called from any thread.
                    nonisolated(unsafe) let completionHandler = completionHandler
                    onUpdate(HealthObserverUpdate(
                        type: type,
                        error: error,
                        completion: HealthObserverCompletion { completionHandler() },
                    ))
                }
                store.execute(query)
                queries.append(query)
                do {
                    try await store.enableBackgroundDelivery(for: sampleType, frequency: .hourly)
                } catch {
                    failed.append(type)
                }
            }
            observerQueries.withLock { $0 = queries }
            if !failed.isEmpty {
                throw HealthObserverError.backgroundDeliveryFailed(failed)
            }
        }

        public func stopObserving() async {
            let queries = observerQueries.withLock { queries in
                defer { queries = [] }
                return queries
            }
            queries.forEach(store.stop)
        }
    }

    public extension HealthWriteType {
        /// The unit of `HealthSampleDraft.value` (`unitSymbol`).
        var unit: HKUnit {
            switch self {
            case .dietaryEnergyConsumed: .kilocalorie()
            case .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber, .dietarySugar: .gram()
            case .dietarySodium: .gramUnit(with: .milli)
            case .dietaryWater: .literUnit(with: .milli)
            case .bodyMass: .gramUnit(with: .kilo)
            }
        }
    }
#endif
