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
    /// Open Food Facts (live HTTP client; a stub in tests and previews). Used by the barcode pipeline.
    let openFoodFacts: any OpenFoodFactsClient
    /// Label photos taken for foods not found by a scan (FR-13); files in the app container, never in the database.
    let labelPhotos: LabelPhotoStore

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
    /// Writes diary and water entries to Health (backlog #27); nil when the database could not be opened.
    let healthWrites: HealthWriteService?

    /// Display preference (Settings → Units); persisted in the `setting` table. Change it with `setEnergyUnit(_:)`.
    private(set) var energyUnit: EnergyUnit = .kcal

    /// The current local day. Stored rather than computed so views re-render when it changes; `refreshToday()`
    /// updates it when the app becomes active or the system reports a significant time change (midnight).
    private(set) var today: LocalDay

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
        openFoodFacts: (any OpenFoodFactsClient)? = nil,
        labelPhotos: LabelPhotoStore = .live,
    ) {
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
                settings: ProfileRepository(db, clock: clock),
                clock: clock,
            )
        } else {
            healthSync = nil
            healthWrites = nil
        }
        self.usdaKeyStore = usdaKeyStore
        self.openFoodFacts = openFoodFacts
            ?? OpenFoodFactsHTTPClient(contact: config.offContact, appVersion: config.appVersion)
        self.labelPhotos = labelPhotos
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

    /// Water logged in Nutrilog (FR-46). The day's total is these entries + `daily_metrics.water_ml` (other apps).
    var water: WaterRepository? {
        db.map { WaterRepository($0, clock: clock) }
    }

    // MARK: Health background work (backlog #26, #27)

    /// At launch (also a background launch for Health delivery): register the observer queries once the user has been
    /// asked for access, start writing queued entries, clean up orphaned samples.
    func startHealthBackgroundWork() {
        healthWrites?.start()
        Task {
            await healthSync?.startObserving()
            await healthWrites?.runMaintenance()
        }
    }

    /// Back in the foreground: retry failed Health writes and clean up orphans (the Health read refresh runs separately).
    func healthDidEnterForeground() async {
        await healthWrites?.runMaintenance()
    }

    /// Onboarding "Connect": shows the permission sheet, starts the backfill and the observers, then writes the
    /// entries that were waiting for write permission (plus the last 7 days' unwritten ones). Throws when the sheet
    /// could not be shown.
    func connectHealth() async throws {
        guard let healthSync else { return }
        try await healthSync.connect()
        await healthWrites?.writeAccessDidChange()
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
    }

    /// Re-reads the clock; returns true when the local day changed.
    @discardableResult
    func refreshToday() -> Bool {
        let current = LocalDay.today(now: clock.now())
        guard current != today else { return false }
        today = current
        return true
    }

    /// Persists the energy unit, then shows it. On failure the previous unit stays.
    func setEnergyUnit(_ unit: EnergyUnit) throws {
        guard unit != energyUnit else { return }
        try profiles?.setSetting(SettingKey.energyUnit, unit.rawValue)
        energyUnit = unit
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

    /// Call after an import replaced or merged data: invalidates pending undo actions and reloads cached settings.
    func dataDidChangeExternally() throws {
        dataGeneration += 1
        try reloadSettings()
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
        return AppEnvironment(
            database: state,
            config: AppConfig(bundle: bundle),
            bundledIndex: BundledFoodIndex.inBundle(bundle),
            health: health,
            healthWriter: health,
            healthObserver: health,
            usdaKeyStore: KeychainUSDAKeyStore(),
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
        openFoodFacts: (any OpenFoodFactsClient)? = nil,
        labelPhotos: LabelPhotoStore? = nil,
    ) -> AppEnvironment {
        let state: DatabaseState
        do { state = try .ready(AppDatabase.inMemory()) } catch { state = .failed(String(describing: error)) }
        let today = LocalDay.today(now: clock.now())
        let health = health ?? (sampleData ? FakeHealthDataSource.demo(endingOn: today) : FakeHealthDataSource())
        let env = AppEnvironment(
            database: state,
            config: AppConfig(usdaAPIKey: nil, offUserAgent: AppConfig.defaultUserAgent),
            bundledIndex: BundledFoodIndex.inBundle(),
            clock: clock,
            health: health,
            healthWriter: healthWriter ?? FakeHealthWriter(mirror: health as? FakeHealthDataSource),
            healthObserver: healthObserver ?? FakeHealthObserver(),
            // Never the network: an empty stub answers "not found".
            openFoodFacts: openFoodFacts ?? StubOpenFoodFactsClient(),
            labelPhotos: labelPhotos ?? .temporary(),
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
            effectiveFrom: today.adding(days: -30), kcal: 2200,
            macros: MacroTargets(proteinG: 160, carbsG: 220, fatG: 75), origin: .manual,
        ))
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
