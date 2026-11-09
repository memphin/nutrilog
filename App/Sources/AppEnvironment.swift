import Core
import Foundation
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

    /// Display preference (Settings → Units); persisted in the `setting` table.
    var energyUnit: EnergyUnit = .kcal {
        didSet { try? profiles?.setSetting(SettingKey.energyUnit, energyUnit.rawValue) }
    }

    init(database: DatabaseState, config: AppConfig, bundledIndex: BundledFoodIndex?, clock: AppClock = .system) {
        self.database = database
        self.config = config
        self.bundledIndex = bundledIndex
        self.clock = clock
        if let raw = try? profiles?.setting(SettingKey.energyUnit, as: String.self), let unit = EnergyUnit(rawValue: raw) {
            energyUnit = unit
        }
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

    var today: LocalDay {
        LocalDay.today(now: clock.now())
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
        return AppEnvironment(database: state, config: AppConfig(bundle: bundle), bundledIndex: BundledFoodIndex.inBundle(bundle))
    }

    /// In-memory environment for tests and previews, optionally with sample data.
    static func preview(sampleData: Bool = false) -> AppEnvironment {
        let state: DatabaseState
        do { state = try .ready(AppDatabase.inMemory()) } catch { state = .failed(String(describing: error)) }
        let env = AppEnvironment(
            database: state,
            config: AppConfig(usdaAPIKey: nil, offUserAgent: AppConfig.defaultUserAgent),
            bundledIndex: BundledFoodIndex.inBundle(),
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

enum SettingKey {
    static let energyUnit = "energyUnit"
    static let waterQuickAddSizes = "waterQuickAddSizes"
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
