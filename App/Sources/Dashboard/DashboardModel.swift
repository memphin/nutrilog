import Core
import Foundation
import Observation
import Persistence

/// State and actions of the Today dashboard (backlog #28) and the weight / water entry (backlog #29).
@MainActor
@Observable
final class DashboardModel {
    private(set) var data: DashboardData
    private(set) var layout: DashboardLayout = .default
    private(set) var waterSizes: [Int] = WaterQuickAdd.defaultSizes
    var errorMessage: String?
    let undo = UndoCenter()

    private let environment: AppEnvironment
    private let calendarProvider: @MainActor () -> Calendar

    /// - Parameter calendar: read on every use, so a time-zone change applies without a new model.
    init(environment: AppEnvironment, calendar: @escaping @MainActor () -> Calendar = { Calendar.current }) {
        self.environment = environment
        calendarProvider = calendar
        data = DashboardData(today: environment.today)
        reloadSettings()
    }

    private var calendar: Calendar {
        calendarProvider()
    }

    var snapshot: DashboardSnapshot {
        DashboardSnapshot(data, calendar: calendar)
    }

    /// Follows `HealthSyncService.requestStatus`, which connect (onboarding, Settings, a tile), every refresh and
    /// app activation update — so the tiles move from "Connect" to loading to values without a relaunch.
    var access: HealthAccess {
        guard let sync = environment.healthSync else {
            return HealthAccess(isAvailable: environment.health.isAvailable, status: .unknown, isConnected: false)
        }
        return HealthAccess(isAvailable: environment.health.isAvailable, status: sync.requestStatus, isConnected: sync.isConnected)
    }

    var energyUnit: EnergyUnit {
        environment.energyUnit
    }

    /// True while the first Health sync runs (tiles without data show "loading" meanwhile). Uses the observable
    /// `phase` and `lastSyncedAt`, so the tiles update when the sync starts and ends.
    var isFirstSync: Bool {
        guard let sync = environment.healthSync, sync.lastSyncedAt == nil else { return false }
        if case .syncing = sync.phase {
            return true
        }
        return false
    }

    func state(of tile: DashboardTile) -> TileState {
        snapshot.state(of: tile, access: access, isFirstSync: isFirstSync)
    }

    // MARK: Loading

    /// Re-reads the settings the dashboard caches (layout, water sizes, step and sleep goals) — they are edited in Settings.
    func reloadSettings() {
        guard let profiles = environment.profiles else { return }
        layout = DashboardLayout.load(from: profiles)
        waterSizes = WaterQuickAdd.sizes(from: profiles)
        let stepGoal = StepGoal.load(from: profiles)
        if data.stepGoal != stepGoal {
            data.stepGoal = stepGoal
        }
        let sleepGoal = SleepGoal.load(from: profiles)
        if data.sleepGoalMin != sleepGoal {
            data.sleepGoalMin = sleepGoal
        }
    }

    func reloadAccess() async {
        await environment.healthSync?.reloadAuthorization()
    }

    /// Streams everything the tiles show for `environment.today`; restarted by the view when the day changes.
    func observe() async {
        let today = environment.today
        if data.today != today {
            data = DashboardData(today: today, stepGoal: data.stepGoal, sleepGoalMin: data.sleepGoalMin, goalMode: data.goalMode)
        }
        await reloadAccess()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeMetrics() }
            group.addTask { await self.observeWeights() }
            group.addTask { await self.observeWater() }
            group.addTask { await self.observeDiary(today) }
            group.addTask { await self.observeTarget(today) }
            group.addTask { await self.observeWaterGoal() }
        }
    }

    private func observeMetrics() async {
        guard let repo = environment.dailyMetrics else { return }
        let window = data.window
        await DiaryModel.resubscribing { repo.observeMetrics(in: window) } onValue: { data.metrics = $0 } onError: { report($0) }
    }

    private func observeWeights() async {
        guard let repo = environment.weights else { return }
        let interval = data.weightInterval(calendar: calendar)
        await DiaryModel.resubscribing { repo.observeEntries(in: interval) } onValue: { data.manualWeights = $0 } onError: { report($0) }
    }

    /// One observation for the sparkline's 7 days: today's entries for the tile, daily totals for the chart.
    private func observeWater() async {
        guard let repo = environment.water else { return }
        let window = data.sparklineWindow
        let today = data.today
        await DiaryModel.resubscribing { repo.observeEntries(in: window) } onValue: { entries in
            data.water = entries.filter { $0.day == today }
            data.waterByDay = entries.reduce(into: [:]) { $0[$1.day, default: 0] += $1.ml }
        } onError: { report($0) }
    }

    private func observeDiary(_ day: LocalDay) async {
        guard let repo = environment.diary else { return }
        await DiaryModel.resubscribing { repo.observeDiary(for: day) } onValue: { data.totals = $0.totals } onError: { report($0) }
    }

    private func observeTarget(_ day: LocalDay) async {
        guard let repo = environment.profiles else { return }
        await DiaryModel.resubscribing { repo.observeTarget(on: day) } onValue: { data.target = $0 } onError: { report($0) }
    }

    private func observeWaterGoal() async {
        guard let repo = environment.profiles else { return }
        await DiaryModel.resubscribing { repo.observeProfile() } onValue: { profile in
            if let goal = profile?.waterGoalMl {
                data.waterGoalMl = goal
            }
            if let mode = profile?.goalMode, data.goalMode != mode {
                data.goalMode = mode
            }
        } onError: { report($0) }
    }

    /// Pull-to-refresh: writes pending Health changes, re-reads Health.
    func refresh() async {
        await environment.refreshHealth()
        await reloadAccess()
    }

    /// Onboarding "Connect" from a tile that needs access.
    func connectHealth() async {
        do {
            try await environment.connectHealth()
        } catch {
            errorMessage = "Couldn't connect Apple Health: \(error.localizedDescription)"
        }
        environment.markHealthOnboardingShown()
        await reloadAccess()
    }

    // MARK: Water (FR-46)

    /// Logs `ml` now and offers undo (which soft-deletes the entry again).
    func addWater(ml: Int) {
        guard let water = environment.water else { return }
        do {
            let entry = try water.add(ml: Double(ml), day: environment.today)
            offerUndo("Added \(ml) ml water") { try water.softDelete(ids: [entry.id]) }
        } catch {
            errorMessage = "Couldn't log water: \(error.localizedDescription)"
        }
    }

    /// Deletes logged water entries and offers undo (restore).
    func deleteWater(_ entries: [WaterEntry]) {
        guard let water = environment.water, !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        do {
            try water.softDelete(ids: ids)
            let total = entries.reduce(0) { $0 + $1.ml }
            offerUndo("Removed \(DashboardFormat.ml(total)) water") { try water.restore(ids: ids) }
        } catch {
            errorMessage = "Couldn't remove water: \(error.localizedDescription)"
        }
    }

    // MARK: Weight (FR-42)

    /// The manual weigh-in that counts for today (the one entered last), for the weight sheet's "edit instead" hint.
    var todaysManualWeight: WeightEntry? {
        let calendar = calendar
        return data.manualWeights
            .filter { LocalDay($0.measuredAt, calendar: calendar) == data.today }
            .max { ($0.createdAt, $0.measuredAt) < ($1.createdAt, $1.measuredAt) }
    }

    /// Saves a new weigh-in, or changes `editing`. Returns false (and sets `errorMessage`) on failure.
    @discardableResult
    func saveWeight(kg: Double, bodyFatPct: Double?, measuredAt: Date, editing: WeightEntry? = nil) -> Bool {
        guard let weights = environment.weights else { return false }
        do {
            if let editing {
                try weights.update(id: editing.id, kg: kg, bodyFatPct: bodyFatPct, measuredAt: measuredAt)
            } else {
                try weights.add(kg: kg, bodyFatPct: bodyFatPct, measuredAt: measuredAt)
            }
            environment.refreshStoredWeightTrend()
            environment.widgetDataDidChange()
            return true
        } catch {
            errorMessage = "Couldn't save the weight: \(error.localizedDescription)"
            return false
        }
    }

    func deleteWeight(_ entry: WeightEntry) {
        guard let weights = environment.weights else { return }
        do {
            try weights.softDelete(ids: [entry.id])
            environment.refreshStoredWeightTrend()
            environment.widgetDataDidChange()
            offerUndo("Deleted \(DashboardFormat.kg(entry.kg))") { [environment] in
                try weights.restore(ids: [entry.id])
                environment.refreshStoredWeightTrend()
                environment.widgetDataDidChange()
            }
        } catch {
            errorMessage = "Couldn't delete the weight: \(error.localizedDescription)"
        }
    }

    /// Every manual weigh-in, newest first, while the weight detail's "All weigh-ins" list is open (nil before the
    /// first value). The dashboard only reads its history window; entries older than that can be corrected here.
    private(set) var allManualWeights: [WeightEntry]?

    /// Streams `allManualWeights` until cancelled (the list's `.task`), so edits, deletes and undo show up at once.
    func observeAllWeights() async {
        guard let repo = environment.weights else {
            allManualWeights = []
            return
        }
        await DiaryModel.resubscribing { repo.observeAllEntries() } onValue: { allManualWeights = $0 } onError: { report($0) }
    }

    // MARK: Detail data

    /// The last `TileHistory.days` days of `tile`, newest first.
    func history(for tile: DashboardTile) -> [TileHistoryRow] {
        let days = (0 ..< TileHistory.days).map { data.today.adding(days: -$0) }
        var kcal: [LocalDay: Double] = [:]
        var water: [LocalDay: Double] = [:]
        if tile == .energy, let diary = environment.diary {
            for day in days {
                if let dayDiary = try? diary.diary(for: day), dayDiary.entryCount > 0 {
                    kcal[day] = dayDiary.totals.kcal
                }
            }
        }
        if tile == .water, let repo = environment.water {
            for day in days {
                water[day] = try? repo.totalMl(for: day)
            }
        }
        return TileHistory.rows(
            for: tile, data: data, kcalByDay: kcal, loggedWaterByDay: water, energyUnit: energyUnit, calendar: calendar,
        )
    }

    // MARK: Helpers

    private func offerUndo(_ message: String, _ action: @escaping () throws -> Void) {
        let generation = environment.dataGeneration
        undo.offer(message) { [weak self] in
            guard let self, environment.dataGeneration == generation else { return }
            do {
                try action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func report(_ error: any Error) {
        errorMessage = error.localizedDescription
    }
}
