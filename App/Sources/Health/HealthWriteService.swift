import Core
import Foundation
import HealthKitClient
import Observation
import Persistence

/// Mirrors diary and water entries to Apple Health (backlog #27, FR-43, FR-46).
///
/// How it works:
/// - The repositories queue every changed row in `healthkit_outbox`, in the same transaction as the change. The diary
///   never waits for Health: this service drains the queue afterwards, triggered by a database observation.
/// - For each queued row: delete every sample Nutrilog wrote for it (by `HKMetadataKeyExternalUUID`, so lost links
///   cannot leave strays), then — if the row is active — write its samples again and replace its `healthkit_link`
///   rows. Save, edit, move and undo are therefore all "rewrite", delete is "delete".
/// - A failed row stays queued with its attempt count and error, and is retried on the next drain: launch,
///   foreground, pull-to-refresh, or the next change. The diary entry itself is never affected.
/// - Only types the user allowed are written or deleted; Health doesn't let an app touch others.
/// - Orphan cleanup (launch, foreground): links whose row is deleted or missing → delete the samples, then the links.
/// - Writing off (Settings): the queue is discarded and nothing is written or deleted, so samples already in Health
///   stay as they are. Rows changed while off are not written later.
///
/// Loop prevention (SPEC §3.4): only `diary_entry` and `water_entry` rows are ever written. Health reads go to
/// `daily_metrics` only, and `HealthSyncService` leaves Nutrilog's own water out of `daily_metrics.water_ml`.
@MainActor
@Observable
final class HealthWriteService {
    let writer: any HealthWriting
    private let links: HealthKitLinkRepository
    private let diary: DiaryRepository
    private let water: WaterRepository
    private let settings: ProfileRepository
    private let calendarProvider: @MainActor () -> Calendar

    /// "Write to Apple Health" (Settings → Apple Health); persisted, on by default.
    private(set) var isEnabled: Bool
    /// Rows waiting to be written (pending or failed), refreshed after every drain.
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
        settings: ProfileRepository,
        calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
    ) {
        self.writer = writer
        self.links = links
        self.diary = diary
        self.water = water
        self.settings = settings
        calendarProvider = calendar
        isEnabled = (try? settings.setting(SettingKey.healthWriteEnabled, as: Bool.self)) ?? true
        updateCounts()
    }

    /// Turns writing on or off. Off discards the queue and leaves existing samples alone; on starts writing new
    /// changes (rows changed while off are not written).
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
        let allowed = await authorizedTypes()
        for item in items {
            do {
                try await process(item, allowed: allowed)
                try links.complete(item)
            } catch {
                try? links.recordFailure(item, error: error.localizedDescription)
            }
        }
    }

    private func process(_ item: HealthKitOutboxItem, allowed: Set<HealthWriteType>) async throws {
        // Manual weights are not mirrored yet (the weight UI, backlog #29, adds them); leave their samples alone.
        guard item.ownerTable != .weightEntry else { return }
        let target = try drafts(for: item)
        let types = Self.types(for: item.ownerTable).intersection(allowed)
        // Delete first: everything written for the row before, found by its external id.
        if !types.isEmpty {
            try await writer.deleteSamples(externalID: item.ownerID, types: types)
        }
        let drafts = (target ?? []).filter { allowed.contains($0.type) }
        guard target != nil, !drafts.isEmpty else {
            try links.deleteLinks(for: item.ownerTable, id: item.ownerID)
            return
        }
        let uuids = try await writer.save(drafts)
        try links.replaceLinks(
            for: item.ownerTable,
            id: item.ownerID,
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
            return HealthSamples.dietary(entry.nutrients, date: date, externalID: entry.id, version: entry.revision)
        case .waterEntry:
            guard let entry = try water.entry(id: item.ownerID), entry.deletedAt == nil else { return nil }
            let date = HealthSamples.date(day: entry.day, loggedAt: entry.loggedAt, calendar: calendar)
            return HealthSamples.water(ml: entry.ml, date: date, externalID: entry.id, version: entry.revision)
        case .weightEntry:
            return nil // not mirrored yet, see `process`
        }
    }

    /// Links whose row was deleted or vanished (crash, import) → delete their samples and the links.
    private func cleanUpOrphans() async {
        guard isEnabled, writer.isAvailable, let orphans = try? links.orphans(), !orphans.isEmpty else { return }
        let allowed = await authorizedTypes()
        for orphan in orphans {
            let types = Set(HealthWriteType.allCases.filter { orphan.hkTypes.contains($0.identifier) })
                .intersection(allowed)
            // On failure the links stay, so the next launch or foreground tries again.
            if !types.isEmpty {
                guard await (try? writer.deleteSamples(externalID: orphan.ownerID, types: types)) != nil else { continue }
            }
            try? links.deleteLinks(for: orphan.ownerTable, id: orphan.ownerID)
        }
    }

    private func authorizedTypes() async -> Set<HealthWriteType> {
        var allowed: Set<HealthWriteType> = []
        for type in HealthWriteType.allCases where await writer.writeAuthorization(for: type) == .authorized {
            allowed.insert(type)
        }
        return allowed
    }

    private static func types(for owner: HealthKitOwner) -> Set<HealthWriteType> {
        switch owner {
        case .diaryEntry: HealthWriteType.dietaryNutrients
        case .waterEntry: [.dietaryWater]
        case .weightEntry: [.bodyMass]
        }
    }

    private func updateCounts() {
        let items = (try? links.pending()) ?? []
        queuedCount = items.count
        let failed = items.filter { $0.attempts > 0 }
        failedCount = failed.count
        if let error = failed.last?.lastError {
            lastError = error
        } else if failed.isEmpty {
            lastError = nil
        }
    }
}
