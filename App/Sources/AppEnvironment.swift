import Core
import FoodLookup
import FoodSources
import Foundation
import HealthKitClient
import Observation
import Persistence

/// Dependency container shared through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    enum DatabaseState {
        case ready(AppDatabase)
        case failed(String)
    }

    let database: DatabaseState
    let config: AppConfig
    let bundledIndex: BundledFoodIndex?
    let clock: AppClock
    /// Apple Health (live on device, a fake in tests and previews).
    let health: any HealthDataSource
    /// Keeps `daily_metrics` in sync with Health; nil when the database could not be opened.
    let healthSync: HealthSyncService?
    /// Holds the user-entered USDA key (Settings).
    let usdaKeyStore: any USDAKeyStoring
    /// Names what a photo shows, on the phone, for matching against local foods when the model can't take a photo.
    let imageLabeler: any FoodImageLabeling
    /// Estimates a meal from a photo or a description with the on-device Apple Intelligence model. Where that
    /// isn't available, Smart log matches foods on the phone instead.
    let mealEstimator: any MealEstimating
    /// Open Food Facts (live HTTP client; a stub in tests and previews). Used by the barcode pipeline.
    let openFoodFacts: any OpenFoodFactsClient
    /// Label photos taken for foods not found by a scan (FR-13); files in the app container, never in the database.
    let labelPhotos: LabelPhotoStore
    /// Open Food Facts full-text search for the Online segment of Add Food (#22); a stub in tests and previews.
    let offSearch: any OpenFoodFactsSearchClient

    /// The app's one USDA 429 cool-down, shared by every client built here. Reset only when the resolved key changes.
    let usdaRateLimit = USDARateLimit()

    /// Where the USDA key in use comes from. Change it with `saveUSDAKey(_:)` / `removeUSDAKey()`.
    private(set) var usdaKeySource: USDAKeySource
    /// True while the Keychain can't be read (e.g. before the first unlock after a reboot). Not the same as "no saved
    /// key": a key may be stored. `reloadUSDAKey()` retries when the app becomes active or protected data unlocks.
    private(set) var usdaKeychainUnreadable: Bool
    /// USDA FoodData Central client for online search (#22). Rebuilt when the resolved key changes; without a key
    /// `usda.isAvailable` is false and the source is hidden.
    private(set) var usda: any USDAClient
    /// The key `usda` was built with.
    private var usdaKey: String?
    /// Writes diary, water and manual weight entries to Health (backlog #27, #29); nil when the database could not be opened.
    let healthWrites: HealthWriteService?

    /// Display preference (Settings → Units); persisted in the `setting` table. Change it with `setEnergyUnit(_:)`.
    private(set) var energyUnit: EnergyUnit = .kcal

    /// The current local day. Stored rather than computed so views re-render when it changes; `refreshToday()`
    /// updates it when the app becomes active or the system reports a significant time change (midnight).
    private(set) var today: LocalDay

    /// The tab shown; set to jump between tabs (e.g. the history calendar opening a day in the diary).
    var selectedTab: AppTab = .today
    /// A day the diary should show next; the diary clears it once applied. Set through `openDiary(on:)`.
    var diaryDayRequest: LocalDay?
    /// A tile whose detail Today should open next; Today clears it once applied. Set through `openDashboardTile(_:)`.
    var dashboardTileRequest: DashboardTile?
    /// The opt-in weekly check-in reminder (a local notification, backlog #35); a no-op in tests and previews.
    let checkInReminder: any CheckInReminderScheduling
    /// The opt-in hydration reminder (a local notification, spec §4); a no-op in tests and previews.
    let hydrationReminder: any HydrationReminderScheduling
    /// Keeps the hydration reminder in line with today's drinks; nil when the database could not be opened.
    let hydrationReminderService: HydrationReminderService?
    /// Folder of the automatic local backups (FR-62); nil turns them off (tests, previews).
    let backupsDirectory: URL?

    /// Writing the entries that waited for Health write permission, started by `connectHealth()` (tests await it).
    @ObservationIgnored private(set) var healthWriteCatchUp: Task<Void, Never>?

    /// Bumped when the database contents change outside the normal flows (JSON import), so screens drop
    /// state that may no longer match the data, such as a pending undo.
    private(set) var dataGeneration = 0

    init(
        database: DatabaseState,
        config: AppConfig,
        bundledIndex: BundledFoodIndex?,
        clock: AppClock = .system,
        health: any HealthDataSource = FakeHealthDataSource(isAvailable: false),
        healthWriter: (any HealthWriting)? = nil,
        healthObserver: (any HealthObserving)? = nil,
        usdaKeyStore: any USDAKeyStoring = InMemoryUSDAKeyStore(),
        mealEstimator: any MealEstimating = NoMealEstimator(),
        imageLabeler: any FoodImageLabeling = NoFoodImageLabeler(),
        // Network-free / throwaway defaults so tests can't reach OFF or write into the app container; `live()`
        // passes the real ones.
        openFoodFacts: any OpenFoodFactsClient = StubOpenFoodFactsClient(),
        labelPhotos: LabelPhotoStore = .temporary(),
        offSearch: any OpenFoodFactsSearchClient = StubOpenFoodFactsSearchClient(),
        checkInReminder: any CheckInReminderScheduling = NoCheckInReminder(),
        hydrationReminder: any HydrationReminderScheduling = NoHydrationReminder(),
        // Where the hydration reminder remembers its last plan across launches; nil keeps it in memory.
        hydrationReminderDefaults: UserDefaults? = nil,
        backupsDirectory: URL? = nil,
    ) {
        self.checkInReminder = checkInReminder
        self.hydrationReminder = hydrationReminder
        self.backupsDirectory = backupsDirectory
        self.database = database
        self.config = config
        self.bundledIndex = bundledIndex
        self.clock = clock
        self.health = health
        if case let .ready(db) = database {
            healthSync = HealthSyncService(
                source: health,
                observer: healthObserver,
                metrics: DailyMetricsRepository(db, clock: clock),
                settings: ProfileRepository(db, clock: clock),
                clock: clock,
            )
            healthWrites = HealthWriteService(
                writer: healthWriter ?? FakeHealthWriter(isAvailable: false),
                links: HealthKitLinkRepository(db, clock: clock),
                diary: DiaryRepository(db, clock: clock),
                water: WaterRepository(db, clock: clock),
                weights: WeightRepository(db, clock: clock),
                settings: ProfileRepository(db, clock: clock),
                clock: clock,
            )
            hydrationReminderService = HydrationReminderService(
                database: db, scheduler: hydrationReminder, clock: clock, defaults: hydrationReminderDefaults,
            )
        } else {
            healthSync = nil
            healthWrites = nil
            hydrationReminderService = nil
        }
        self.usdaKeyStore = usdaKeyStore
        self.imageLabeler = imageLabeler
        self.mealEstimator = mealEstimator
        self.openFoodFacts = openFoodFacts
        self.labelPhotos = labelPhotos
        self.offSearch = offSearch
        let resolved = Self.resolveUSDAKey(store: usdaKeyStore, config: config)
        usdaKeySource = resolved.source
        usdaKeychainUnreadable = resolved.unreadable
        usdaKey = resolved.key
        usda = USDAHTTPClient(apiKey: resolved.key, rateLimit: usdaRateLimit)
        today = LocalDay.today(now: clock.now())
        try? reloadSettings() // unreadable settings fall back to the defaults
    }

    var db: AppDatabase? {
        if case let .ready(db) = database {
            return db
        }
        return nil
    }

    var foods: FoodRepository? {
        db.map { FoodRepository($0, clock: clock) }
    }

    var diary: DiaryRepository? {
        db.map { DiaryRepository($0, clock: clock) }
    }

    var profiles: ProfileRepository? {
        db.map { ProfileRepository($0, clock: clock) }
    }

    var search: FoodSearch? {
        db.map { FoodSearch($0, bundled: bundledIndex) }
    }

    var portability: DataPortability? {
        db.map { DataPortability($0, clock: clock) }
    }

    var dailyMetrics: DailyMetricsRepository? {
        db.map { DailyMetricsRepository($0, clock: clock) }
    }

    /// Water quick-adds logged in Vitalion (FR-46). The day's hydration total also counts diary and caffeine drinks
    /// (`hydration`) and other apps' water (`daily_metrics.water_ml`): `WaterProgress`.
    var water: WaterRepository? {
        db.map { WaterRepository($0, clock: clock) }
    }

    /// Caffeine quick-adds logged in Vitalion; `observeIntakes(in:)` adds the caffeine of diary entries.
    var caffeine: CaffeineRepository? {
        db.map { CaffeineRepository($0, clock: clock) }
    }

    /// Everything drunk (water quick-adds, diary fluids, caffeine drinks) as `FluidIntake`s per day.
    var hydration: HydrationRepository? {
        db.map { HydrationRepository($0) }
    }

    // MARK: Health background work (backlog #26, #27)

    /// At launch (also a background launch for Health delivery): register the observer queries once the user has been
    /// asked for access, start writing queued entries, clean up orphaned samples. Also brings the check-in reminder in
    /// line with its stored setting (e.g. after a reinstall from a backup).
    func startHealthBackgroundWork() {
        healthWrites?.start()
        reconcileCheckInReminder()
        Task {
            await healthSync?.startObserving()
            await healthWrites?.runMaintenance()
        }
    }

    /// Back in the foreground: retry failed Health writes and clean up orphans (the Health read refresh runs separately).
    func healthDidEnterForeground() async {
        await healthWrites?.runMaintenance()
    }

    /// Onboarding "Connect": shows the permission sheet, starts the backfill and the observers, then starts writing the
    /// entries that were waiting for write permission (plus the last 7 days' unwritten ones). Doesn't wait for those
    /// writes — a long backlog must not hold the sheet; `healthWriteCatchUp` is that work. Throws when the sheet could
    /// not be shown.
    func connectHealth() async throws {
        guard let healthSync else { return }
        try await healthSync.connect()
        if let healthWrites {
            // Drains are serialised inside the service (one pass at a time, a request during a pass adds one more).
            healthWriteCatchUp = Task { await healthWrites.writeAccessDidChange() }
        }
    }

    /// Pull-to-refresh (dashboard): retry pending Health writes, then re-read Health. Returns when done.
    func refreshHealth() async {
        await healthWrites?.drain()
        await healthSync?.pullToRefresh()
    }

    /// Barcode → local food / OFF product (backlog #19); nil when the database could not be opened.
    var barcodeLookup: BarcodeLookup? {
        db.map { BarcodeLookup(database: $0, client: openFoodFacts, clock: clock) }
    }

    /// True once per install: Health is available, the user was never asked for access, and the onboarding
    /// explanation has not been shown yet.
    func shouldShowHealthOnboarding() async -> Bool {
        guard health.isAvailable, let profiles,
              (try? profiles.setting(SettingKey.healthOnboardingShown, as: Bool.self)) != true
        else { return false }
        return await health.authorizationRequestStatus() == .shouldRequest
    }

    /// Remembers that the first-launch Health onboarding was shown (whatever the user chose).
    func markHealthOnboardingShown() {
        try? profiles?.setSetting(SettingKey.healthOnboardingShown, true)
    }

    /// The clock jumped or the time zone changed (`significantTimeChangeNotification`, system time zone change):
    /// re-read "today" and re-sync every Health day, since day boundaries may have moved.
    func systemTimeDidChange() async {
        refreshToday()
        await healthSync?.refresh(force: true)
        refreshHydrationReminder() // the reminder's time of day may have moved
    }

    /// Re-reads the clock; returns true when the local day changed (the hydration reminder then plans the new day).
    @discardableResult
    func refreshToday() -> Bool {
        let current = LocalDay.today(now: clock.now())
        guard current != today else { return false }
        today = current
        refreshHydrationReminder()
        return true
    }

    /// Persists the energy unit, then shows it. On failure the previous unit stays.
    func setEnergyUnit(_ unit: EnergyUnit) throws {
        guard unit != energyUnit else { return }
        try profiles?.setSetting(SettingKey.energyUnit, unit.rawValue)
        energyUnit = unit
        widgetDataDidChange() // the widgets show energy in this unit
    }

    /// Reloads the settings cached here from the database.
    func reloadSettings() throws {
        guard let profiles else { return }
        let raw = try profiles.setting(SettingKey.energyUnit, as: String.self)
        energyUnit = raw.flatMap(EnergyUnit.init(rawValue:)) ?? .kcal
    }

    /// Saves a user-entered USDA key in the Keychain; it then wins over the build-config key. Blank keys are ignored.
    func saveUSDAKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try usdaKeyStore.save(key)
        reloadUSDAKey()
    }

    /// Removes the user-entered USDA key; the build-config key (if any) applies again.
    func removeUSDAKey() throws {
        try usdaKeyStore.delete()
        reloadUSDAKey()
    }

    /// Re-reads the Keychain and re-resolves the USDA key (Keychain, then build config, then none). The client and
    /// its cool-down are kept when the key is unchanged; a different key gets a new client and a reset cool-down.
    /// Called on launch, after Save/Remove, when the app becomes active and when protected data becomes available.
    func reloadUSDAKey() {
        let resolved = Self.resolveUSDAKey(store: usdaKeyStore, config: config)
        if usdaKeySource != resolved.source {
            usdaKeySource = resolved.source
        }
        if usdaKeychainUnreadable != resolved.unreadable {
            usdaKeychainUnreadable = resolved.unreadable
        }
        guard resolved.key != usdaKey else { return }
        usdaKey = resolved.key
        usdaRateLimit.reset()
        usda = USDAHTTPClient(apiKey: resolved.key, rateLimit: usdaRateLimit)
    }

    /// An unreadable Keychain falls back to the build-config key and is reported as `unreadable`.
    private static func resolveUSDAKey(
        store: any USDAKeyStoring,
        config: AppConfig,
    ) -> (key: String?, source: USDAKeySource, unreadable: Bool) {
        let saved: String?
        let unreadable: Bool
        do {
            saved = try store.load()
            unreadable = false
        } catch {
            saved = nil
            unreadable = true
        }
        let resolved = USDAKeySource.resolve(saved: saved, buildConfig: config.usdaAPIKey)
        return (resolved.key, resolved.source, unreadable)
    }

    /// Call after an import replaced or merged data (synchronously, before the Health queue gets a chance to drain):
    /// invalidates pending undo actions, reloads cached settings — the energy unit and "Write to Apple Health", so the
    /// rows the import queued are written or discarded by the stored choice — reconciles the check-in and hydration
    /// reminders with the stored settings and refreshes the widgets.
    func dataDidChangeExternally() throws {
        dataGeneration += 1
        healthWrites?.reloadStoredSetting()
        reconcileCheckInReminder()
        refreshHydrationReminder()
        defer { widgetDataDidChange() }
        try reloadSettings()
    }

    /// Schedules or cancels the weekly check-in notification to match the stored toggle and weekday (they arrive with
    /// an import or restore, which doesn't touch the notification itself). Never asks for notification permission:
    /// without it, nothing is scheduled. Returns the work, for tests; nil when the settings can't be read.
    @discardableResult
    func reconcileCheckInReminder() -> Task<Void, Never>? {
        guard let profiles else { return nil }
        let wanted: Bool
        do {
            wanted = try profiles.setting(SettingKey.checkInReminderEnabled, as: Bool.self) ?? false // missing means off
        } catch {
            return nil // unreadable: leave the notification as it is
        }
        let weekday = (try? profiles.profile().checkinWeekday) ?? 2
        let reminder = checkInReminder
        return Task {
            guard wanted else {
                await reminder.cancel()
                return
            }
            guard await reminder.isAuthorized() else { return }
            try? await reminder.schedule(weekday: weekday, hour: LocalNotificationCheckInReminder.defaultHour)
        }
    }

    /// Production environment: on-disk database in Application Support + bundled food index.
    static func live(bundle: Bundle = .main) -> AppEnvironment {
        let state: DatabaseState
        do {
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Database", isDirectory: true)
            state = try .ready(AppDatabase.onDisk(directory: dir))
        } catch {
            state = .failed(String(describing: error))
        }
        if case let .ready(db) = state {
            Task.detached(priority: .background) {
                // The OFF product cache only holds re-fetchable data: drop entries older than 90 days (backlog #19).
                _ = try? BarcodeLookup.evictExpiredCache(in: db)
            }
        }
        let health = LiveHealthDataSource()
        let config = AppConfig(bundle: bundle)
        return AppEnvironment(
            database: state,
            config: config,
            bundledIndex: BundledFoodIndex.inBundle(bundle),
            health: health,
            healthWriter: health,
            healthObserver: health,
            usdaKeyStore: KeychainUSDAKeyStore(),
            mealEstimator: AppleMealEstimator(),
            imageLabeler: VisionFoodImageLabeler(),
            openFoodFacts: OpenFoodFactsHTTPClient(contact: config.offContact, appVersion: config.appVersion),
            labelPhotos: .live,
            offSearch: OpenFoodFactsSearchHTTPClient(contact: config.offContact, appVersion: config.appVersion),
            checkInReminder: LocalNotificationCheckInReminder(),
            hydrationReminder: LocalNotificationHydrationReminder(),
            hydrationReminderDefaults: .standard,
            backupsDirectory: try? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Backups", isDirectory: true),
        )
    }

    /// In-memory environment for tests and previews, optionally with sample data. Health is a fake: with sample
    /// data it is already connected and holds demo values, otherwise it is empty and not yet authorized.
    static func preview(
        sampleData: Bool = false,
        clock: AppClock = .system,
        health: (any HealthDataSource)? = nil,
        healthWriter: (any HealthWriting)? = nil,
        healthObserver: (any HealthObserving)? = nil,
        mealEstimator: any MealEstimating = NoMealEstimator(),
        openFoodFacts: (any OpenFoodFactsClient)? = nil,
        labelPhotos: LabelPhotoStore? = nil,
        checkInReminder: (any CheckInReminderScheduling)? = nil,
        hydrationReminder: (any HydrationReminderScheduling)? = nil,
        backupsDirectory: URL? = nil,
    ) -> AppEnvironment {
        let state: DatabaseState
        do { state = try .ready(AppDatabase.inMemory()) } catch { state = .failed(String(describing: error)) }
        let today = LocalDay.today(now: clock.now())
        let health = health ?? (sampleData ? FakeHealthDataSource.demo(endingOn: today) : FakeHealthDataSource())
        let env = AppEnvironment(
            database: state,
            config: AppConfig(usdaAPIKey: nil),
            bundledIndex: BundledFoodIndex.inBundle(),
            clock: clock,
            health: health,
            healthWriter: healthWriter ?? FakeHealthWriter(mirror: health as? FakeHealthDataSource),
            healthObserver: healthObserver ?? FakeHealthObserver(),
            mealEstimator: mealEstimator,
            // Never the network: an empty stub answers "not found".
            openFoodFacts: openFoodFacts ?? StubOpenFoodFactsClient(),
            labelPhotos: labelPhotos ?? .temporary(),
            checkInReminder: checkInReminder ?? NoCheckInReminder(),
            hydrationReminder: hydrationReminder ?? NoHydrationReminder(),
            backupsDirectory: backupsDirectory,
        )
        if sampleData {
            env.insertSampleData()
        }
        return env
    }

    private func insertSampleData() {
        guard let foods, let diary, let profiles else { return }
        let today = today
        let oats = try? foods.save(FoodDetail(
            food: Food(name: "Oats", per100: Nutrients(kcal: 379, proteinG: 13.2, carbsG: 67.7, fatG: 6.5, fiberG: 10)),
            servings: [Serving(label: "cup", grams: 80)],
        )).food
        let milk = try? foods.save(FoodDetail(
            food: Food(
                name: "Milk 2.8%",
                brand: "Dukat",
                per100: Nutrients(kcal: 59, proteinG: 3.3, carbsG: 4.7, fatG: 2.8),
                isLiquid: true,
            ),
        )).food
        if let oats {
            _ = try? diary.log(food: oats, quantity: .base(60), slotID: "breakfast", day: today)
        }
        if let milk {
            _ = try? diary.log(food: milk, quantity: .base(250), slotID: "breakfast", day: today)
        }
        _ = try? diary.logQuickAdd(
            name: "Lunch out",
            nutrients: Nutrients(kcal: 750, proteinG: 35, carbsG: 80, fatG: 28),
            slotID: "lunch",
            day: today,
        )
        _ = try? profiles.setTarget(Target(
            effectiveFrom: today.adding(days: -60), kcal: 2200,
            macros: MacroTargets(proteinG: 160, carbsG: 220, fatG: 75), origin: .manual,
        ))
        insertSampleHistory(oats: oats, milk: milk)
        insertSamplePlan(oats: oats, milk: milk)
        insertSampleCaffeine()
    }

    /// A meal plan for the coming days: tonight's dinner, and the same prepped lunch for the rest of the week.
    private func insertSamplePlan(oats: Food?, milk: Food?) {
        guard let foods, let mealPlan else { return }
        let chicken = try? foods.save(FoodDetail(food: Food(
            name: "Chicken breast, cooked", per100: Nutrients(kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6),
        ))).food
        let rice = try? foods.save(FoodDetail(food: Food(
            name: "Rice, cooked", per100: Nutrients(kcal: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3),
        ))).food
        guard let chicken, let rice else { return }
        let prepped: [DiaryRepository.LogItem] = [.init(food: chicken, quantity: .base(150)), .init(food: rice, quantity: .base(200))]
        _ = try? mealPlan.planAll(prepped, slotID: "dinner", day: today)
        for offset in 1 ... 4 {
            _ = try? mealPlan.planAll(prepped, slotID: "lunch", day: today.adding(days: offset))
        }
        if let oats, let milk {
            _ = try? mealPlan.planAll(
                [.init(food: oats, quantity: .base(60)), .init(food: milk, quantity: .base(250))], slotID: "breakfast", day: today.next,
            )
        }
    }

    /// A cola last evening and two coffees earlier today (relative to now), so the caffeine tile has a curve.
    private func insertSampleCaffeine() {
        guard let caffeine else { return }
        let now = clock.now()
        let calendar = Calendar.current
        let yesterdayEvening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today.adding(days: -1).startDate())
        let drinks: [(CaffeineDrink, Date?)] = [
            (.cola, yesterdayEvening),
            (.espresso, now.addingTimeInterval(-5 * 3600)),
            (.filterCoffee, now.addingTimeInterval(-2 * 3600)),
        ]
        for (drink, date) in drinks {
            guard let date, date <= now else { continue }
            _ = try? caffeine.add(
                mg: drink.mg, day: LocalDay(date, calendar: calendar), loggedAt: date, drinkID: drink.id, name: drink.name,
            )
        }
    }

    /// Six weeks of diary history, a complete profile and a saved meal, so the Trends screens (maintenance
    /// estimate, check-in, calendar, charts, weekly report) have something to show. Weights come from the demo Health data.
    private func insertSampleHistory(oats: Food?, milk: Food?) {
        guard let foods, let diary, let profiles, let meals else { return }
        if var profile = try? profiles.profile() {
            profile.heightCm = 182
            profile.birthDate = LocalDay(year: 1988, month: 4, day: 12)
            profile.sex = .male
            profile.activityLevel = .light
            profile.goalMode = .lose
            profile.goalRateKgPerWeek = 0.25
            try? profiles.save(profile)
        }
        // Deterministic day-to-day variation around 2,250 kcal; every tenth day is left unlogged.
        let swing: [Double] = [0, 120, -180, 60, 260, -90, -140, 310, -40, 90]
        for offset in 1 ... 45 where offset % 10 != 4 {
            let day = today.adding(days: -offset)
            let kcal = 2250 + swing[offset % swing.count]
            let meals: [(String, Double)] = [("breakfast", 0.25), ("lunch", 0.4), ("dinner", 0.35)]
            for (slot, share) in meals {
                let part = kcal * share
                _ = try? diary.logQuickAdd(
                    name: slot.capitalized, nutrients: Nutrients(
                        kcal: part,
                        proteinG: part * 0.28 / 4,
                        carbsG: part * 0.42 / 4,
                        fatG: part * 0.3 / 9,
                    ),
                    slotID: slot, day: day,
                )
            }
        }
        if let oats, let milk {
            _ = try? meals.create(name: "Overnight oats", items: [.init(foodID: oats.id, grams: 40), .init(foodID: milk.id, grams: 125)])
            _ = try? meals.createFromDiary(day: today, slotID: "breakfast", name: "Usual breakfast")
            try? foods.setFavorite(id: milk.id, true)
        }
    }
}

/// Where the USDA FoodData Central key in use comes from (ADR-0004). The Keychain key wins over the build-config one.
enum USDAKeySource: Equatable {
    /// Entered by the user in Settings.
    case keychain
    /// `USDA_FDC_API_KEY` from Config/Secrets.xcconfig, via Info.plist `USDAFDCAPIKey`.
    case buildConfig
    /// No key: online USDA search is unavailable; the app works with the bundled foods and Open Food Facts.
    case none

    /// The key to use and its source: `saved`, else `buildConfig`, else none. Blank keys count as missing.
    static func resolve(saved: String?, buildConfig: String?) -> (key: String?, source: USDAKeySource) {
        func usable(_ key: String?) -> String? {
            guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
            return key
        }
        if let key = usable(saved) {
            return (key, .keychain)
        }
        if let key = usable(buildConfig) {
            return (key, .buildConfig)
        }
        return (nil, .none)
    }
}

enum SettingKey {
    static let energyUnit = "energyUnit"
    static let waterQuickAddSizes = "waterQuickAddSizes"
    /// Date: when the last Health sync finished successfully (backlog #24).
    static let healthLastSyncedAt = "healthLastSyncedAt"
    /// Date: when the last full 90-day Health sync finished successfully.
    static let healthLastFullSyncAt = "healthLastFullSyncAt"
    /// Bool: the first-launch Health onboarding was shown.
    static let healthOnboardingShown = "healthOnboardingShown"
    /// Bool: "Write to Apple Health" (Settings → Apple Health, backlog #27); missing means on.
    static let healthWriteEnabled = "healthWriteEnabled"
    /// Bool: the weekly check-in reminder notification is on (backlog #35); missing means off.
    static let checkInReminderEnabled = "checkInReminderEnabled"
    /// String ("YYYY-MM-DD"): the last day the check-in sheet opened by itself, so it does so once a day at most.
    static let checkInPromptedDay = "checkInPromptedDay"
    /// Double (mg): the "sleep safe" caffeine line; missing means `CaffeineDefaults.sleepSafeThresholdMg`.
    static let caffeineThresholdMg = "caffeineThresholdMg"
    /// Int (minutes from midnight): bedtime for the caffeine tile; missing means `CaffeineDefaults.defaultBedtimeMinutes`.
    static let caffeineBedtimeMinutes = "caffeineBedtimeMinutes"
    /// Bool: smoker (shorter caffeine half-life, `CaffeineMetabolism.smoker`); missing means false.
    static let caffeineSmoker = "caffeineSmoker"
    /// Bool: takes oral contraceptives (`CaffeineMetabolism.oralContraceptives`); missing means false.
    static let caffeinePill = "caffeinePill"
    /// Bool: pregnant (`CaffeineMetabolism.pregnant`); missing means false.
    static let caffeinePregnant = "caffeinePregnant"
    /// Double (hours): a caffeine half-life set by hand (`CaffeineMetabolism.overrideHours`); missing means derived.
    static let caffeineHalfLifeOverride = "caffeineHalfLifeOverride"
    /// [String]: `CaffeineDrink` ids of the caffeine quick-add buttons; missing means `CaffeineDrink.defaultQuickAddIDs`.
    static let caffeineQuickAddDrinks = "caffeineQuickAddDrinks"
    /// Int (minutes from midnight): wake-up time when Apple Health has no sleep for the day; missing means 07:00.
    static let hydrationFallbackWakeMinutes = "hydrationFallbackWakeMinutes"
    /// Int (minutes): a stretch without a drink longer than this is a gap; missing means 180.
    static let hydrationGapMinutes = "hydrationGapMinutes"
    /// Double (ml): how far below the pace line counts as behind; missing means 500.
    static let hydrationBehindMarginMl = "hydrationBehindMarginMl"
    /// Bool: hydration reminder notifications are on; missing means off.
    static let hydrationRemindersEnabled = "hydrationRemindersEnabled"
}

/// kcal or kJ for display (Settings → Units). Storage is always kcal.
enum EnergyUnit: String, CaseIterable, Identifiable {
    case kcal
    case kilojoules = "kJ"

    var id: String {
        rawValue
    }

    var symbol: String {
        rawValue
    }

    static let kJPerKcal = 4.184

    func display(_ kcal: Double) -> Double {
        self == .kcal ? kcal : kcal * Self.kJPerKcal
    }

    func fromDisplay(_ value: Double) -> Double {
        self == .kcal ? value : value / Self.kJPerKcal
    }

    func format(_ kcal: Double) -> String {
        "\(display(kcal).formatted(.number.precision(.fractionLength(0)))) \(symbol)"
    }
}
