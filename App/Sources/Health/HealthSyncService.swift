import Core
import Foundation
import HealthKitClient
import Observation
import Persistence

/// Copies Apple Health into the `daily_metrics` cache (backlog #24): the last 90 days once after the first
/// authorization, then the recent days on every refresh. Health stays the system of record; every sync simply
/// recomputes the rows of the days it reads.
@MainActor
@Observable
final class HealthSyncService {
    /// Days read after the first authorization (and kept in sync at most).
    static let backfillDays = 90
    /// Days re-read on every refresh: Watch data can arrive late, and last night's sleep belongs to today.
    static let recentDays = 3
    /// The backfill reads this many days per query batch, newest first, so recent days appear first.
    static let backfillChunkDays = 30
    /// An automatic refresh this soon after the last sync is skipped.
    static let minimumRefreshInterval: TimeInterval = 5 * 60

    enum Phase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    let source: any HealthDataSource
    private let metrics: DailyMetricsRepository
    private let settings: ProfileRepository
    private let clock: AppClock
    private let calendar: Calendar

    private(set) var phase: Phase = .idle
    /// When Health was last read successfully (persisted as `daily_metrics.fetched_at`).
    private(set) var lastSyncedAt: Date?
    @ObservationIgnored private var running: Task<Void, Never>?

    init(
        source: any HealthDataSource,
        metrics: DailyMetricsRepository,
        settings: ProfileRepository,
        clock: AppClock = .system,
        calendar: Calendar = .current,
    ) {
        self.source = source
        self.metrics = metrics
        self.settings = settings
        self.clock = clock
        self.calendar = calendar
        lastSyncedAt = try? metrics.lastFetchedAt()
    }

    var today: LocalDay {
        LocalDay.today(calendar: calendar, now: clock.now())
    }

    /// The days the cache covers: the last `backfillDays` days up to today.
    var window: ClosedRange<LocalDay> {
        today.adding(days: -(Self.backfillDays - 1)) ... today
    }

    var isBackfillComplete: Bool {
        (try? settings.setting(SettingKey.healthBackfillCompleted, as: Bool.self)) == true
    }

    /// Shows the Health permission sheet (after the onboarding explanation), then reads Health — the full
    /// backfill the first time.
    func connect() async throws {
        try await source.requestAuthorization()
        await run()
    }

    /// Reads the recent days, or finishes the backfill if it never completed. Does nothing before the user has
    /// been asked for access, or within `minimumRefreshInterval` of the last sync unless `force` is set
    /// (pull-to-refresh).
    func refresh(force: Bool = false) async {
        guard source.isAvailable, running == nil else {
            await running?.value
            return
        }
        if !force, let lastSyncedAt, clock.now().timeIntervalSince(lastSyncedAt) < Self.minimumRefreshInterval {
            return
        }
        guard isBackfillComplete else {
            // Asked before (e.g. on a previous install) but never backfilled: do it now.
            if await source.authorizationRequestStatus() == .unnecessary {
                await run()
            }
            return
        }
        await run()
    }

    /// Reads `days` from Health and writes their rows. Returns the number of rows inserted or changed.
    @discardableResult
    func sync(days: ClosedRange<LocalDay>) async throws -> Int {
        let batch = try await source.fetchDailyData(for: days, calendar: calendar)
        let rows = DailyMetricsAggregator.aggregate(batch, calendar: calendar)
        return try metrics.upsert(rows)
    }

    /// Runs one sync at a time; a call while one is running waits for it instead of starting another.
    private func run() async {
        if let running {
            await running.value
            return
        }
        let task = Task { await self.performSync() }
        running = task
        await task.value
        running = nil
    }

    private func performSync() async {
        phase = .syncing
        do {
            let today = today
            if isBackfillComplete {
                let lastDay = try settings.setting(SettingKey.healthLastSyncedDay, as: LocalDay.self) ?? today
                // Re-read the recent days, and every day since the last sync if the app was not opened for a while.
                let start = max(window.lowerBound, min(today.adding(days: -(Self.recentDays - 1)), lastDay))
                try await sync(days: start ... today)
            } else {
                var end = today
                while end >= window.lowerBound {
                    let start = max(window.lowerBound, end.adding(days: -(Self.backfillChunkDays - 1)))
                    try await sync(days: start ... end)
                    end = start.previous
                }
                try settings.setSetting(SettingKey.healthBackfillCompleted, true)
            }
            try settings.setSetting(SettingKey.healthLastSyncedDay, today)
            lastSyncedAt = clock.now()
            phase = .idle
        } catch {
            phase = .failed("Couldn't read Apple Health: \(error.localizedDescription)")
        }
    }
}
