import Core
import Foundation
import HealthKitClient
import Observation
import Persistence

/// Mirrors diary, water and manual weight entries to Apple Health (backlog #27, #29, FR-42, FR-43, FR-46).
///
/// How it works:
/// - The repositories queue every changed row in `healthkit_outbox`, in the same transaction as the change (imports
///   too). The diary never waits for Health: this service drains the queue afterwards, triggered by a database
///   observation of the queue's generation counter.
/// - For each queued row: delete every sample Nutrilog wrote for it (by `HKMetadataKeyExternalUUID`, so lost links
///   cannot leave strays), then — if the row is active — write its samples again and replace its `healthkit_link`
///   rows. Save, edit, move and undo are therefore all "rewrite", delete is "delete". A brand-new row (no links, never
///   attempted) skips the delete.
/// - Every attempt is counted before it starts, and the sample sync version is `revision * 1000 + attempt`, so a
///   retry after a failure or a crash always outranks a copy Health may already hold.
/// - A failed row stays queued with its attempt count and error, and is retried on the next drain: launch,
///   foreground, pull-to-refresh, or the next change. The diary entry itself is never affected.
/// - Permissions: only types the user allowed are written or deleted, and only their links change (links of other
///   types keep describing what is still in Health). A row none of whose types is allowed yet, with some still
///   undecided, stays queued until the user answers; `writeAccessDidChange()` then drains it and also queues the
///   last 7 days' entries that were never written.
/// - Orphan cleanup (launch, foreground): links whose row is deleted or missing → delete the samples, then the links.
/// - Writing off (Settings): the queue is discarded and nothing is written or deleted — a pass in progress stops
///   after the row it is writing — so samples already in Health stay as they are. Turning it back on resumes orphan
///   cleanup (samples of entries deleted meanwhile are removed at the next launch or foreground) and writes new
///   changes; entries edited while off keep their old values in Health until they are edited again.
///
/// Loop prevention (SPEC §3.4): only `diary_entry`, `water_entry` and `weight_entry` rows are ever written. Health
/// reads go to `daily_metrics` only, and `HealthSyncService` leaves Nutrilog's own water, weight and body fat out of
/// it, so nothing written here is read back as another app's data.
@MainActor
@Observable
final class HealthWriteService {
    /// How many days back `writeAccessDidChange()` looks for entries that were never written.
    static let lateGrantDays = 7

    let writer: any HealthWriting
    private let links: HealthKitLinkRepository
    private let diary: DiaryRepository
    private let water: WaterRepository
    private let weights: WeightRepository
    private let settings: ProfileRepository
    private let clock: AppClock
    private let calendarProvider: @MainActor () -> Calendar

    /// "Write to Apple Health" (Settings → Apple Health); persisted, on by default.
    private(set) var isEnabled: Bool
    /// Rows waiting to be written (pending, failed, or waiting for permission), refreshed after every drain.
    private(set) var queuedCount = 0
    /// Rows whose last attempt failed.
    private(set) var failedCount = 0
    /// The error of the most recent failure, for Settings.
    private(set) var lastError: String?

    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var needsDrain = false
    @ObservationIgnored private var needsCleanup = false
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(
        writer: any HealthWriting,
        links: HealthKitLinkRepository,
        diary: DiaryRepository,
        water: WaterRepository,
        weights: WeightRepository,
        settings: ProfileRepository,
        clock: AppClock = .system,
        calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
    ) {
        self.writer = writer
        self.links = links
        self.diary = diary
        self.water = water
        self.weights = weights
        self.settings = settings
        self.clock = clock
        calendarProvider = calendar
        isEnabled = (try? settings.setting(SettingKey.healthWriteEnabled, as: Bool.self)) ?? true
        updateCounts()
    }

    /// Why the last toggle change could not be saved (shown in Settings); nil after a successful change.
    private(set) var settingError: String?

    /// The Settings toggle, bound directly (`$writes.writeToHealth`) so the view needs no `Bool` closures. A failure
    /// to persist leaves the value unchanged and sets `settingError`.
    var writeToHealth: Bool {
        get { isEnabled }
        set {
            do {
                try setEnabled(newValue)
                settingError = nil
            } catch {
                settingError = "Couldn't save the setting: \(error.localizedDescription)"
            }
        }
    }

    /// Turns writing on or off. Off discards the queue, stops a pass in progress after its current row and leaves
    /// existing samples alone. On writes new changes and resumes orphan cleanup; rows changed while off are not
    /// written later.
    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        try settings.setSetting(SettingKey.healthWriteEnabled, enabled)
        isEnabled = enabled
        if !enabled {
            try links.discardPending()
            updateCounts()
        }
    }

    /// Drains the queue whenever a row is queued. Call once at launch.
    func start() {
        guard observation == nil else { return }
        let queue = links.observeQueue()
        observation = Task { [weak self] in
            do {
                for try await _ in queue {
                    await self?.drain()
                }
            } catch {
                // The observation ends only when the database is closed; launch and foreground still drain.
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Launch / foreground: orphan cleanup, then retry everything queued.
    func runMaintenance() async {
        needsCleanup = true
        await perform()
    }

    /// Writes everything queued. Returns when the queue has been processed once (failed rows stay queued).
    func drain() async {
        await perform()
    }

    /// The user answered the Health permission sheet: write the rows that were waiting for permission, and queue the
    /// last `lateGrantDays` days' entries that were never written (access granted after logging, without a backfill).
    /// When body fat writing is allowed, recent weights with body fat but no body-fat sample are queued too (body fat
    /// was added in an update, after those weights were written).
    func writeAccessDidChange() async {
        if isEnabled {
            let calendar = calendarProvider()
            let today = LocalDay.today(calendar: calendar, now: clock.now())
            let since = today.adding(days: -(Self.lateGrantDays - 1))
            _ = try? links.enqueueUnlinked(since: since, calendar: calendar)
            if writer.isAvailable, await writer.writeAuthorization(for: .bodyFatPercentage) == .authorized {
                _ = try? links.enqueueWeights(missing: HealthWriteType.bodyFatPercentage.identifier, since: since, calendar: calendar)
            }
        }
        await drain()
    }

    /// Waits until no drain is running.
    func waitUntilIdle() async {
        while let running {
            await running.value
        }
    }

    // MARK: Processing

    /// Runs one pass at a time in the service's own task; a request while a pass runs adds one more pass.
    private func perform() async {
        needsDrain = true
        if running == nil {
            running = Task {
                while needsDrain {
                    needsDrain = false
                    if needsCleanup {
                        needsCleanup = false
                        await cleanUpOrphans()
                    }
                    await processQueue()
                }
                running = nil
            }
        }
        await waitUntilIdle()
    }

    private func processQueue() async {
        defer { updateCounts() }
        guard isEnabled else {
            try? links.discardPending()
            return
        }
        guard writer.isAvailable, let items = try? links.pending(), !items.isEmpty else { return }
        let statuses = await authorizationStatuses()
        for item in items {
            guard isEnabled else { return } // turned off during the pass: leave everything else alone
            let ownerTypes = Self.types(for: item.ownerTable)
            let allowed = ownerTypes.filter { statuses[$0] == .authorized }
            if allowed.isEmpty {
                // Not asked yet: keep the row until the user answers (`writeAccessDidChange`). All denied: done.
                // Only the owner's main types count (a weight waits for body mass, not for body fat, which an update
                // added and which may stay unanswered for a long time).
                if !Self.holdingTypes(for: item.ownerTable).contains(where: { statuses[$0] == .notDetermined }) {
                    try? links.complete(item)
                }
                continue
            }
            // nil: completed, discarded or queued again meanwhile — the newer generation is handled on its own.
            guard let attempt = try? links.markAttempt(item) else { continue }
            do {
                try await process(attempt, isFirstAttempt: item.attempts == 0, allowed: allowed)
                try links.complete(attempt)
            } catch {
                try? links.recordFailure(attempt, error: error.localizedDescription)
            }
        }
    }

    private func process(_ item: HealthKitOutboxItem, isFirstAttempt: Bool, allowed: Set<HealthWriteType>) async throws {
        let target = try drafts(for: item)
        let identifiers = Set(allowed.map(\.identifier))
        // Delete first: everything written for the row before, found by its external id. A new row that was never
        // written (no links, first attempt) has nothing in Health yet.
        let hasLinks = try !links.links(for: item.ownerTable, id: item.ownerID).isEmpty
        let isNew = target != nil && isFirstAttempt && !hasLinks
        if !isNew {
            try await writer.deleteSamples(externalID: item.ownerID, types: allowed)
        }
        let drafts = (target ?? []).filter { allowed.contains($0.type) }
        guard target != nil, !drafts.isEmpty else {
            try links.deleteLinks(for: item.ownerTable, id: item.ownerID, types: identifiers)
            return
        }
        let uuids = try await writer.save(drafts)
        try links.replaceLinks(
            for: item.ownerTable,
            id: item.ownerID,
            types: identifiers,
            with: zip(drafts, uuids).map { ($0.type.identifier, $1.uuidString.lowercased()) },
        )
    }

    /// The samples a row should have in Health; nil when it is deleted or gone (its samples must go).
    private func drafts(for item: HealthKitOutboxItem) throws -> [HealthSampleDraft]? {
        let calendar = calendarProvider()
        switch item.ownerTable {
        case .diaryEntry:
            guard let entry = try diary.entry(id: item.ownerID), entry.deletedAt == nil else { return nil }
            let hour = try diary.mealSlots(includeInactive: true).first { $0.id == entry.mealSlotID }?.defaultStartHour
            let date = HealthSamples.date(day: entry.day, loggedAt: entry.loggedAt, fallbackHour: hour, calendar: calendar)
            let version = HealthSamples.syncVersion(revision: entry.revision, attempt: item.attempts)
            return HealthSamples.dietary(entry.nutrients, date: date, externalID: entry.id, version: version)
        case .waterEntry:
            guard let entry = try water.entry(id: item.ownerID), entry.deletedAt == nil else { return nil }
            let date = HealthSamples.date(day: entry.day, loggedAt: entry.loggedAt, calendar: calendar)
            let version = HealthSamples.syncVersion(revision: entry.revision, attempt: item.attempts)
            return HealthSamples.water(ml: entry.ml, date: date, externalID: entry.id, version: version)
        case .weightEntry:
            guard let entry = try weights.entry(id: item.ownerID), entry.deletedAt == nil else { return nil }
            let version = HealthSamples.syncVersion(revision: entry.revision, attempt: item.attempts)
            return HealthSamples.weight(
                kg: entry.kg, bodyFatPct: entry.bodyFatPct, date: entry.measuredAt, externalID: entry.id, version: version,
            )
        }
    }

    /// Links whose row was deleted or vanished (crash, import) → delete their samples and those links. Paused while
    /// writing is off (and stops mid-pass when it is turned off); resumes when it is turned back on. Links of types
    /// the app may not touch stay until it may.
    private func cleanUpOrphans() async {
        guard isEnabled, writer.isAvailable, let orphans = try? links.orphans(), !orphans.isEmpty else { return }
        let statuses = await authorizationStatuses()
        for orphan in orphans {
            guard isEnabled else { return }
            let types = Set(HealthWriteType.allCases.filter {
                orphan.hkTypes.contains($0.identifier) && statuses[$0] == .authorized
            })
            guard !types.isEmpty else { continue }
            // On failure the links stay, so the next launch or foreground tries again.
            guard await (try? writer.deleteSamples(externalID: orphan.ownerID, types: types)) != nil else { continue }
            try? links.deleteLinks(for: orphan.ownerTable, id: orphan.ownerID, types: Set(types.map(\.identifier)))
        }
    }

    private func authorizationStatuses() async -> [HealthWriteType: HealthWriteAuthorization] {
        var statuses: [HealthWriteType: HealthWriteAuthorization] = [:]
        for type in HealthWriteType.allCases {
            statuses[type] = await writer.writeAuthorization(for: type)
        }
        return statuses
    }

    private static func types(for owner: HealthKitOwner) -> Set<HealthWriteType> {
        switch owner {
        case .diaryEntry: HealthWriteType.dietaryNutrients
        case .waterEntry: [.dietaryWater]
        case .weightEntry: HealthWriteType.body
        }
    }

    /// While one of these is undetermined and nothing can be written, the row waits for the user's answer.
    static func holdingTypes(for owner: HealthKitOwner) -> Set<HealthWriteType> {
        owner == .weightEntry ? [.bodyMass] : types(for: owner)
    }

    private func updateCounts() {
        let items = (try? links.pending()) ?? []
        queuedCount = items.count
        let failed = items.filter { $0.lastError != nil }
        failedCount = failed.count
        lastError = failed.last?.lastError
    }
}
