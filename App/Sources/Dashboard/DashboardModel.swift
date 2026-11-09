import Core
import Foundation
import Observation
import Persistence

/// State and actions of the Today dashboard (backlog #28) and the weight / water entry (backlog #29).
@MainActor
@Observable
final class DashboardModel {
    private(set) var data: DashboardData
    private(set) var access: HealthAccess = .requested
    private(set) var layout: DashboardLayout = .default
    private(set) var waterSizes: [Int] = WaterQuickAdd.defaultSizes
    var errorMessage: String?
    let undo = UndoCenter()

    private let environment: AppEnvironment
    private let calendar: Calendar

    init(environment: AppEnvironment, calendar: Calendar = .current) {
        self.environment = environment
        self.calendar = calendar
        data = DashboardData(today: environment.today)
        reloadSettings()
    }

    var snapshot: DashboardSnapshot {
        DashboardSnapshot(data, calendar: calendar)
    }

    var energyUnit: EnergyUnit {
        environment.energyUnit
    }

    /// True until the first Health sync has finished (tiles without data show "loading" meanwhile).
    var isFirstSync: Bool {
        guard let sync = environment.healthSync else { return false }
        return sync.lastSyncedAt == nil && sync.isSyncing
    }

    func state(of tile: DashboardTile) -> TileState {
        snapshot.state(of: tile, access: access, isFirstSync: isFirstSync)
    }

    // MARK: Loading

    /// Re-reads the settings the dashboard caches (layout, water sizes).
    func reloadSettings() {
        guard let profiles = environment.profiles else { return }
        layout = DashboardLayout.load(from: profiles)
        waterSizes = WaterQuickAdd.sizes(from: profiles)
    }

    func reloadAccess() async {
        let status = await environment.health.authorizationRequestStatus()
        access = HealthAccess(isAvailable: environment.health.isAvailable, status: status)
    }

    /// Streams everything the tiles show for `environment.today`; restarted by the view when the day changes.
    func observe() async {
        let today = environment.today
        if data.today != today {
            data = DashboardData(today: today)
        }
        await reloadAccess()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeMetrics() }
            group.addTask { await self.observeWeights() }
            group.addTask { await self.observeWater(today) }
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

    private func observeWater(_ day: LocalDay) async {
        guard let repo = environment.water else { return }
        await DiaryModel.resubscribing { repo.observeEntries(for: day) } onValue: { data.water = $0 } onError: { report($0) }
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

    // MARK: Layout

    func setVisible(_ tile: DashboardTile, _ visible: Bool) {
        var updated = layout
        updated.setVisible(tile, visible)
        saveLayout(updated)
    }

    func moveTiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = layout
        updated.move(fromOffsets: source, toOffset: destination)
        saveLayout(updated)
    }

    func resetLayout() {
        saveLayout(.default)
    }

    private func saveLayout(_ updated: DashboardLayout) {
        guard let profiles = environment.profiles else { return }
        do {
            try updated.save(to: profiles)
            layout = updated
        } catch {
            errorMessage = "Couldn't save the dashboard layout: \(error.localizedDescription)"
        }
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
            offerUndo("Deleted \(DashboardFormat.kg(entry.kg))") { try weights.restore(ids: [entry.id]) }
        } catch {
            errorMessage = "Couldn't delete the weight: \(error.localizedDescription)"
        }
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
