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

    // MARK: Editing the layout

    /// True while Today is in edit mode (long-press a tile): tiles can be dragged, hidden and shown.
    var isEditing = false

    func moveTile(_ tile: DashboardTile, onto target: DashboardTile) {
        updateLayout { $0.move(tile, onto: target) }
    }

    func moveTile(_ tile: DashboardTile, by offset: Int) {
        updateLayout { $0.move(tile, by: offset) }
    }

    func hideTile(_ tile: DashboardTile) {
        updateLayout { $0.setVisible(tile, false) }
    }

    func showTile(_ tile: DashboardTile) {
        updateLayout { $0.show(tile) }
    }

    /// Applies `change` and saves it (the same setting Settings → Dashboard edits); the layout changes only when the
    /// save worked.
    private func updateLayout(_ change: (inout DashboardLayout) -> Void) {
        guard let profiles = environment.profiles else { return }
        var updated = layout
        change(&updated)
        guard updated != layout else { return }
        do {
            try updated.save(to: profiles)
            layout = updated
        } catch {
            errorMessage = "Couldn't save the dashboard layout: \(error.localizedDescription)"
        }
    }

    // MARK: Loading

    /// Re-reads the settings the dashboard caches (layout, water sizes, step and sleep goals, caffeine, hydration) —
    /// they are edited in Settings.
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
        let caffeineSettings = CaffeineSettings.load(from: profiles)
        if data.caffeineSettings != caffeineSettings {
            data.caffeineSettings = caffeineSettings
        }
        let hydrationSettings = HydrationSettings.load(from: profiles)
        if data.hydrationSettings != hydrationSettings {
            data.hydrationSettings = hydrationSettings
        }
    }

    func reloadAccess() async {
        await environment.healthSync?.reloadAuthorization()
    }

    /// Streams everything the tiles show for `environment.today`; restarted by the view when the day changes.
    func observe() async {
        let today = environment.today
        if data.today != today {
            data = DashboardData(
                today: today, waterGoalMl: data.waterGoalMl, waterGoalMode: data.waterGoalMode,
                hydrationSettings: data.hydrationSettings, stepGoal: data.stepGoal, sleepGoalMin: data.sleepGoalMin,
                goalMode: data.goalMode, caffeineSettings: data.caffeineSettings,
            )
        }
        await reloadAccess()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeMetrics() }
            group.addTask { await self.observeWeights() }
            group.addTask { await self.observeWater(today) }
            group.addTask { await self.observeHydration() }
            group.addTask { await self.observeCaffeine() }
            group.addTask { await self.observeDiary(today) }
            group.addTask { await self.observeTarget(today) }
            group.addTask { await self.observeWaterGoal() }
        }
    }

    /// The window's Health rows, and with them the weight trends of the hydration goal (a trend from before the
    /// window counts too, so they are read from the database rather than from the rows).
    private func observeMetrics() async {
        guard let repo = environment.dailyMetrics else { return }
        let window = data.window
        await DiaryModel.resubscribing { repo.observeMetrics(in: window) } onValue: { rows in
            data.metrics = rows
            let trends = HydrationGoalResolver.trendsKg(in: window, from: repo)
            if data.weightTrends != trends {
                data.weightTrends = trends
            }
        } onError: { report($0) }
    }

    private func observeWeights() async {
        guard let repo = environment.weights else { return }
        let interval = data.weightInterval(calendar: calendar)
        await DiaryModel.resubscribing { repo.observeEntries(in: interval) } onValue: { data.manualWeights = $0 } onError: { report($0) }
    }

    /// Today's water entries, for the detail's list.
    private func observeWater(_ day: LocalDay) async {
        guard let repo = environment.water else { return }
        await DiaryModel.resubscribing { repo.observeEntries(for: day) } onValue: { data.water = $0 } onError: { report($0) }
    }

    /// Every drink of the sparkline's 7 days in one observation: today's for the tile, daily totals for the chart.
    private func observeHydration() async {
        guard let repo = environment.hydration else { return }
        let window = data.sparklineWindow
        await DiaryModel.resubscribing { repo.observeIntakes(in: window) } onValue: { data.hydrationIntakes = $0 } onError: { report($0) }
    }

    /// Yesterday's and today's caffeine, quick-adds and diary entries in one observation.
    private func observeCaffeine() async {
        guard let repo = environment.caffeine else { return }
        let window = data.caffeineWindow
        await DiaryModel.resubscribing { repo.observeIntakes(in: window) } onValue: { data.caffeine = $0 } onError: { report($0) }
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
            if let mode = profile?.waterGoalMode, data.waterGoalMode != mode {
                data.waterGoalMode = mode
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

    // MARK: Hydration (FR-46)

    /// Today's hydration at `now`, for the tile and the detail.
    func hydrationDay(at now: Date) -> HydrationDay {
        snapshot.hydrationDay(now: now, calendar: calendar)
    }

    /// Logs `ml` drunk now (or at `loggedAt`, on that time's day) and offers undo (which soft-deletes the entry
    /// again).
    func addWater(ml: Int, loggedAt: Date? = nil) {
        guard let water = environment.water else { return }
        do {
            let day = loggedAt.map { LocalDay($0, calendar: calendar) } ?? environment.today
            let entry = try water.add(ml: Double(ml), day: day, loggedAt: loggedAt)
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

    /// Deletes a water or caffeine quick-add from the Hydration detail and offers undo (restore). Diary drinks are
    /// changed in the diary, so they are left alone.
    func deleteIntake(_ intake: FluidIntake) {
        switch intake.source {
        case .water:
            guard let water = environment.water else { return }
            do {
                try water.softDelete(ids: [intake.id])
                offerUndo("Removed \(DashboardFormat.ml(intake.ml)) water") { try water.restore(ids: [intake.id]) }
            } catch {
                errorMessage = "Couldn't remove water: \(error.localizedDescription)"
            }
        case .caffeine:
            guard let caffeine = environment.caffeine else { return }
            do {
                try caffeine.softDelete(ids: [intake.id])
                offerUndo("Removed \(intake.name)") { try caffeine.restore(ids: [intake.id]) }
            } catch {
                errorMessage = "Couldn't remove the drink: \(error.localizedDescription)"
            }
        case .diary:
            return
        }
    }

    /// The meal each diary drink of `intakes` was logged in (its slot's name), by intake id. Drinks from other
    /// sources, and entries or slots that can't be read, are absent.
    func diaryMealNames(for intakes: [FluidIntake]) -> [String: String] {
        let diaryIntakes = intakes.filter { $0.source == .diary }
        guard let diary = environment.diary, !diaryIntakes.isEmpty,
              let slots = try? diary.mealSlots(includeInactive: true) else { return [:] }
        let slotNames = Dictionary(slots.map { ($0.id, $0.name) }) { first, _ in first }
        var names: [String: String] = [:]
        for intake in diaryIntakes {
            if let slotID = (try? diary.entry(id: intake.id))??.mealSlotID, let name = slotNames[slotID] {
                names[intake.id] = name
            }
        }
        return names
    }

    // MARK: Caffeine

    /// The moment the caffeine tile is read at (the app's clock, so tests and previews can move it).
    var now: Date {
        environment.clock.now()
    }

    func caffeineStatus(at now: Date) -> CaffeineStatus {
        snapshot.caffeineStatus(now: now, calendar: calendar)
    }

    /// Today's caffeine intakes for the detail list, newest first.
    var todaysCaffeine: [CaffeineIntakeRow] {
        CaffeineIntakeRow.rows(data.caffeine, on: data.today)
    }

    /// Logs a preset drink now and offers undo.
    func addCaffeine(drink: CaffeineDrink) {
        addCaffeine(mg: drink.mg, at: nil, drinkID: drink.id, name: drink.name)
    }

    /// Logs `mg` of caffeine taken at `at` (nil: now) and offers undo. The entry's day is the day of `at`.
    func addCaffeine(mg: Double, at: Date?, drinkID: String?, name: String?) {
        guard let caffeine = environment.caffeine else { return }
        do {
            let day = at.map { LocalDay($0, calendar: calendar) } ?? environment.today
            let entry = try caffeine.add(mg: mg, day: day, loggedAt: at, drinkID: drinkID, name: name)
            let what = name.map { "\($0) (\(CaffeineStatus.mg(mg)))" } ?? "\(CaffeineStatus.mg(mg)) caffeine"
            offerUndo("Added \(what)") { try caffeine.softDelete(ids: [entry.id]) }
        } catch {
            errorMessage = "Couldn't log caffeine: \(error.localizedDescription)"
        }
    }

    /// Deletes a caffeine quick-add and offers undo (restore). Diary caffeine is removed in the diary.
    func deleteCaffeine(_ entry: CaffeineEntry) {
        guard let caffeine = environment.caffeine else { return }
        do {
            try caffeine.softDelete(ids: [entry.id])
            offerUndo("Removed \(entry.name ?? "caffeine") (\(CaffeineStatus.mg(entry.mg)))") {
                try caffeine.restore(ids: [entry.id])
            }
        } catch {
            errorMessage = "Couldn't remove caffeine: \(error.localizedDescription)"
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
        var fluid: [LocalDay: Double] = [:]
        var caffeine: [LocalDay: Double] = [:]
        if tile == .energy, let diary = environment.diary {
            for day in days {
                if let dayDiary = try? diary.diary(for: day), dayDiary.entryCount > 0 {
                    kcal[day] = dayDiary.totals.kcal
                }
            }
        }
        if tile == .water, let repo = environment.hydration, let first = days.last,
           let intakes = try? repo.intakes(in: first ... data.today)
        {
            fluid = intakes.mapValues { $0.reduce(0) { $0 + $1.ml } }
        }
        if tile == .caffeine, let repo = environment.caffeine, let first = days.last,
           let intakes = try? repo.intakes(in: first ... data.today)
        {
            for day in days {
                caffeine[day] = intakes.totalMg(on: day)
            }
        }
        return TileHistory.rows(
            for: tile, data: data, kcalByDay: kcal, loggedFluidByDay: fluid, caffeineByDay: caffeine,
            energyUnit: energyUnit, calendar: calendar,
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
