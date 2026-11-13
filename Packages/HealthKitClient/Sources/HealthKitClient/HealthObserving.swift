import Foundation
import Synchronization

/// Change notifications from Apple Health (backlog #26, FR-44): one `HKObserverQuery` per read type plus background
/// delivery, so new data (a morning weigh-in, last night's sleep) reaches `daily_metrics` without opening the app.
/// A separate protocol next to `HealthDataSource`: `LiveHealthDataSource` adopts it, tests use `FakeHealthObserver`.
///
/// HealthKit hands every update a completion handler that must be called once the app has dealt with it; an update
/// that is never completed costs background budget and eventually stops background delivery. Pass updates to a
/// `HealthObserverDispatcher`, which guarantees the call.
public protocol HealthObserving: Sendable {
    /// Registers an observer query for each type and enables hourly background delivery for it. Replaces queries of
    /// an earlier call. Characteristic types (date of birth, sex) cannot be observed and are skipped.
    /// Throws `HealthObserverError.backgroundDeliveryFailed` when background delivery could not be enabled for some
    /// types; their observer queries still run while the app does.
    func startObserving(_ types: [HealthReadType], onUpdate: @escaping @Sendable (HealthObserverUpdate) -> Void) async throws

    /// Stops the observer queries (background delivery stays registered with Health until the next start).
    func stopObserving() async
}

public enum HealthObserverError: Error, Equatable, Sendable {
    case backgroundDeliveryFailed([HealthReadType])
}

/// One observer query callback.
public struct HealthObserverUpdate: Sendable {
    public let type: HealthReadType
    /// Set when HealthKit reports an error instead of a change; the update must still be completed.
    public let error: (any Error)?
    public let completion: HealthObserverCompletion

    public init(type: HealthReadType, error: (any Error)?, completion: HealthObserverCompletion) {
        self.type = type
        self.error = error
        self.completion = completion
    }
}

/// Wraps HealthKit's observer completion handler so it runs exactly once, whoever calls it first (the refresh
/// finishing, an error path, a timeout or `stop`).
public final class HealthObserverCompletion: Sendable {
    private let handler: Mutex<(@Sendable () -> Void)?>

    public init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = Mutex(handler)
    }

    /// Calls the handler unless it was already called.
    public func complete() {
        let handler = handler.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?()
    }

    public var isCompleted: Bool {
        handler.withLock { $0 == nil }
    }
}

public extension HealthReadType {
    /// The types worth observing: everything that feeds `daily_metrics`, and workouts (not height and the profile
    /// characteristics, which are read when the profile needs them).
    static var observedTypes: [HealthReadType] {
        allCases.filter { $0.metric != nil || $0.kind == .workout }
    }
}

/// Turns observer updates into refreshes and completes every update, always:
/// - an update carrying an error is completed at once (nothing to refresh);
/// - updates are coalesced: those arriving while a refresh runs share the next refresh (HealthKit fires one update
///   per type at once — on launch, every observed type), and each is completed when that refresh ends;
/// - a refresh that takes longer than `timeout` completes its updates anyway (it keeps running);
/// - `stop()` completes every waiting update and cancels the running refresh.
public actor HealthObserverDispatcher {
    private let refresh: @Sendable (Set<HealthReadType>) async -> Void
    private let timeout: Duration
    private var waiting: [HealthObserverUpdate] = []
    private var running: Task<Void, Never>?
    private var stopped = false

    /// Updates handled so far, by outcome — for tests and diagnostics.
    public private(set) var refreshCount = 0
    public private(set) var errorCount = 0

    /// - Parameters:
    ///   - timeout: how long an update may wait for its refresh before it is completed regardless. Background
    ///     launches get about 30 seconds in total, so stay below that.
    ///   - refresh: re-reads Health for the changed types; called with the types of all coalesced updates.
    public init(timeout: Duration = .seconds(20), refresh: @escaping @Sendable (Set<HealthReadType>) async -> Void) {
        self.timeout = timeout
        self.refresh = refresh
    }

    /// The `onUpdate` handler to pass to `HealthObserving.startObserving`. Returns immediately.
    public nonisolated func handle(_ update: HealthObserverUpdate) {
        guard update.error == nil else {
            update.completion.complete()
            Task { await self.countError() }
            return
        }
        // The deadline runs outside the actor, so even a refresh that never returns cannot hold the update.
        let timeout = timeout
        Task {
            try? await Task.sleep(for: timeout)
            update.completion.complete()
        }
        Task { await self.enqueue(update) }
    }

    /// Completes every waiting update, cancels the running refresh and ignores (but completes) later updates.
    public func stop() {
        stopped = true
        running?.cancel()
        completeWaiting()
    }

    /// Waits until no refresh is running or queued.
    public func waitUntilIdle() async {
        while let running {
            await running.value
        }
    }

    private func countError() {
        errorCount += 1
    }

    private func enqueue(_ update: HealthObserverUpdate) {
        guard !stopped else {
            update.completion.complete()
            return
        }
        waiting.append(update)
        guard running == nil else { return }
        running = Task { await self.drain() }
    }

    private func drain() async {
        while !waiting.isEmpty, !stopped {
            let batch = waiting
            waiting = []
            refreshCount += 1
            await refresh(Set(batch.map(\.type)))
            batch.forEach { $0.completion.complete() }
        }
        completeWaiting()
        running = nil
    }

    private func completeWaiting() {
        let batch = waiting
        waiting = []
        batch.forEach { $0.completion.complete() }
    }
}
