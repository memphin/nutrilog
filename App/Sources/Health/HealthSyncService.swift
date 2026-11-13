import Core
import Foundation
import HealthKitClient
import Observation
import Persistence

/// Copies Apple Health into the `daily_metrics` cache (backlog #24). Health stays the system of record; every
/// sync recomputes the rows of the days it reads.
///
/// - Full sync: the whole 90-day window, newest days first. Runs after authorization, on a forced refresh
///   (Update now, pull-to-refresh, time or time-zone change) and automatically at most once a day, so access
///   granted later and late uploads (a scale or watch syncing days afterwards) still fill the history.
/// - Recent sync: the last `recentDays` days, on launch and whenever the app returns to the foreground.
/// - Observer updates (backlog #26): once the user has been asked for access, an `HKObserverQuery` per read type with
///   hourly background delivery re-reads the recent days whenever Health changes (a morning weigh-in shows up within
///   the hour without opening the app). Every observer completion handler is called by `HealthObserverDispatcher`.
/// The calendar (time zone) is read at the start of every sync, so day boundaries follow the device.
/// Water and weights written by Vitalion itself are left out of `daily_metrics` while their `water_entry` /
/// `weight_entry` row exists (deleted rows included); those whose row is gone (reinstall) are read like other data.
@MainActor
@Observable
final class HealthSyncService {
    /// Days covered by the cache; read in full after authorization and once a day.
    static let windowDays = 90
    /// Days re-read on every automatic refresh: Watch data can arrive late, and last night's sleep belongs to today.
    static let recentDays = 3
    /// Days per Health query batch, newest first, so recent days appear first.
    static let chunkDays = 30
    /// An automatic refresh this soon after the last successful sync is skipped.
    static let minimumRefreshInterval: TimeInterval = 5 * 60
    /// An automatic refresh reads the full window again when the last full sync is at least this old.
    static let fullSyncInterval: TimeInterval = 24 * 3600

    enum Phase: Equatable {
        case idle
        case syncing(daysDone: Int, daysTotal: Int)
        case failed(String)
    }

    enum Scope: Equatable {
        case full
        case recent
    }

    let source: any HealthDataSource
    private let observer: (any HealthObserving)?
    /// Vitalion's own source in Health; its water and weights are not counted as data from other apps.
    private let ownBundleIdentifier: String?
    private let metrics: DailyMetricsRepository
    private let settings: ProfileRepository
    private let clock: AppClock
    private let calendarProvider: @MainActor () -> Calendar

    private(set) var phase: Phase = .idle
    /// When the last sync finished successfully (persisted; a failed or partial sync never updates it).
    private(set) var lastSyncedAt: Date?
    /// When the last full-window sync finished successfully (persisted).
    private(set) var lastFullSyncAt: Date?
    /// Whether Health would show the permission sheet — the one shared, observable copy (dashboard, Settings). Nil
    /// until first read; refreshed by `reloadAuthorization()`, `connect()` and every `refresh()`.
    private(set) var requestStatus: HealthAuthorizationRequestStatus?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var pending: Scope?
    @ObservationIgnored private var dispatcher: HealthObserverDispatcher?
    /// Observer updates handled (each re-read the recent days) — for tests and diagnostics.
    private(set) var observerRefreshCount = 0

    /// - Parameter calendar: the calendar for day boundaries, read at the start of every sync. Defaults to the
    ///   device's current calendar; tests inject a fixed one.
    init(
        source: any HealthDataSource,
        observer: (any HealthObserving)? = nil,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        metrics: DailyMetricsRepository,
        settings: ProfileRepository,
        clock: AppClock = .system,
        calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
    ) {
        self.source = source
        self.observer = observer
        self.ownBundleIdentifier = ownBundleIdentifier
        self.metrics = metrics
        self.settings = settings
        self.clock = clock
        calendarProvider = calendar
        lastSyncedAt = try? settings.setting(SettingKey.healthLastSyncedAt, as: Date.self)
        lastFullSyncAt = try? settings.setting(SettingKey.healthLastFullSyncAt, as: Date.self)
    }

    var today: LocalDay {
        LocalDay.today(calendar: calendarProvider(), now: clock.now())
    }

    /// The days the cache covers: the last `windowDays` days up to today.
    var window: ClosedRange<LocalDay> {
        Self.window(endingOn: today)
    }

    /// True once a full-window sync has completed.
    var isBackfillComplete: Bool {
        lastFullSyncAt != nil
    }

    /// True while a sync runs or is queued.
    var isSyncing: Bool {
        running != nil
    }

    /// The user has connected Health: they answered the permission sheet, or a full sync completed before. The
    /// second case covers an update that added new types (Health then reports `.shouldRequest` again): the user is
    /// still connected, there are just new types to allow.
    var isConnected: Bool {
        requestStatus == .unnecessary || isBackfillComplete
    }

    /// Re-reads whether Health would show the permission sheet.
    func reloadAuthorization() async {
        let status = await source.authorizationRequestStatus()
        if status != requestStatus {
            requestStatus = status
        }
    }

    /// Shows the Health permission sheet (after the onboarding explanation) and returns once the user answered.
    /// The full-window sync then runs in the background; follow it through `phase`.
    func connect() async throws {
        try await source.requestAuthorization()
        await reloadAuthorization()
        startSync(.full)
        await startObserving()
    }

    /// Registers the observer queries and background delivery (launch, and after `connect`). Does nothing before the
    /// user has been asked for access, or when already observing. Background delivery that fails to enable for some
    /// types is not fatal: their queries still update the app while it runs.
    func startObserving() async {
        guard source.isAvailable, let observer, dispatcher == nil else { return }
        if !isBackfillComplete {
            guard await source.authorizationRequestStatus() == .unnecessary else { return }
        }
        guard dispatcher == nil else { return } // started while we were asking
        let dispatcher = HealthObserverDispatcher { [weak self] _ in
            await self?.healthDidChange()
        }
        self.dispatcher = dispatcher
        try? await observer.startObserving(HealthReadType.observedTypes, onUpdate: { dispatcher.handle($0) })
    }

    func stopObserving() async {
        guard let dispatcher else { return }
        self.dispatcher = nil
        await observer?.stopObserving()
        await dispatcher.stop()
    }

    /// Pull-to-refresh (dashboard, Settings): re-reads the whole window now. Returns when the data is in.
    func pullToRefresh() async {
        await refresh(force: true)
    }

    /// An observer reported new data: re-read the recent days (queued behind a running sync), ignoring the
    /// automatic-refresh throttle. Returns when the data is in, so the observer completes after the write.
    private func healthDidChange() async {
        observerRefreshCount += 1
        startSync(.recent)
        await waitForSync()
    }

    /// Automatic refresh (launch, foreground): the recent days, or the full window when the last full sync is a
    /// day old or never completed; skipped within `minimumRefreshInterval` of the last successful sync.
    /// `force` (Update now, pull-to-refresh, time change) always reads the full window.
    /// Does nothing before the user has been asked for access. Returns when the sync has finished.
    func refresh(force: Bool = false) async {
        guard source.isAvailable else { return }
        await reloadAuthorization()
        if !force {
            guard running == nil else { return await waitForSync() }
            if let lastSyncedAt, clock.now().timeIntervalSince(lastSyncedAt) < Self.minimumRefreshInterval {
                return
            }
        }
        if !isBackfillComplete {
            // Asked before (now, or on a previous install) but never fully synced: go ahead; otherwise wait for
            // the onboarding.
            guard await source.authorizationRequestStatus() == .unnecessary else { return }
        }
        if !force, running != nil {
            return await waitForSync() // another refresh started while we were asking
        }
        startSync(force || needsFullSync ? .full : .recent)
        await waitForSync()
    }

    /// Waits until no sync is running or queued.
    func waitForSync() async {
        while let running {
            await running.value
        }
    }

    /// Reads `days` from Health and writes their rows. Returns the number of rows inserted or changed.
    @discardableResult
    func sync(days: ClosedRange<LocalDay>, calendar: Calendar? = nil) async throws -> Int {
        let calendar = calendar ?? calendarProvider()
        let batch = try await source.fetchDailyData(for: days, calendar: calendar)
        let own = ownBundleIdentifier.map { Set([$0]) } ?? []
        // Read after the fetch, so an own sample in the batch whose row was just created is known as local. Own
        // samples with no local row (reinstall, new phone without the backup) are read like any other source's.
        let localIDs: Set<String>? = try own.isEmpty ? nil : metrics.localHealthSampleIDs()
        let rows = DailyMetricsAggregator.aggregate(
            batch, calendar: calendar, excludingOwnSamplesFrom: own, localSampleIDs: localIDs,
        )
        return try metrics.upsert(rows)
    }

    static func window(endingOn today: LocalDay) -> ClosedRange<LocalDay> {
        today.adding(days: -(windowDays - 1)) ... today
    }

    private var needsFullSync: Bool {
        guard let lastFullSyncAt else { return true }
        return clock.now().timeIntervalSince(lastFullSyncAt) >= Self.fullSyncInterval
    }

    /// Runs syncs one at a time in the service's own task. A request while one runs is queued (a full request
    /// wins over a recent one) and runs right after it.
    private func startSync(_ scope: Scope) {
        guard running == nil else {
            pending = pending == .full || scope == .full ? .full : .recent
            return
        }
        running = Task {
            var next: Scope? = scope
            while let current = next {
                await performSync(current)
                next = pending
                pending = nil
            }
            running = nil
        }
    }

    private func performSync(_ scope: Scope) async {
        let calendar = calendarProvider()
        let today = LocalDay.today(calendar: calendar, now: clock.now())
        let window = Self.window(endingOn: today)
        let days = scope == .full ? window : today.adding(days: -(Self.recentDays - 1)) ... today
        let total = days.lowerBound.days(until: days.upperBound) + 1
        phase = .syncing(daysDone: 0, daysTotal: total)
        do {
            var end = days.upperBound
            var done = 0
            while end >= days.lowerBound {
                let start = max(days.lowerBound, end.adding(days: -(Self.chunkDays - 1)))
                try await sync(days: start ... end, calendar: calendar)
                done += start.days(until: end) + 1
                phase = .syncing(daysDone: done, daysTotal: total)
                end = start.previous
            }
            let finished = clock.now()
            if scope == .full {
                try settings.setSetting(SettingKey.healthLastFullSyncAt, finished)
                lastFullSyncAt = finished
            }
            try settings.setSetting(SettingKey.healthLastSyncedAt, finished)
            lastSyncedAt = finished
            phase = .idle
        } catch {
            phase = .failed(String(localized: "Couldn't read Apple Health: \(error.localizedDescription)"))
        }
    }
}
