import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

@MainActor
struct WidgetAndBackupTests {
    let clock = ManualClock()

    @Test func `widget snapshot follows the diary, target, water and Health`() throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let suite = "widget-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try #require(env.profiles).setTarget(Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 67), origin: .manual,
        ))
        let lunch = Nutrients(kcal: 640, proteinG: 40, carbsG: 60, fatG: 20)
        try #require(env.diary).logQuickAdd(name: nil, nutrients: lunch, slotID: "lunch", day: env.today)
        try #require(env.water).add(ml: 500, day: env.today)
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: env.today, steps: 8123, sleepAsleepMin: 431, waterMl: 250)])
        try #require(env.weights).add(kg: 81.4)

        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        let snapshot = try #require(WidgetSnapshot.load(defaults: defaults))
        #expect(snapshot.day == "2026-11-09")
        #expect(snapshot.kcal == 640 && snapshot.targetKcal == 2000)
        #expect(snapshot.proteinG == 40 && snapshot.targetCarbsG == 200)
        #expect(snapshot.steps == 8123 && snapshot.sleepMin == 431)
        #expect(snapshot.waterMl == 750 && snapshot.waterGoalMl == 2450) // 30 ml/kg of the 81.4 kg logged here
        #expect(snapshot.weightKg == 81.4)
        #expect(snapshot.energyUnit == "kcal")

        // Unchanged data: the stored snapshot (and its timestamp) stays, so the widgets aren't reloaded for nothing.
        clock.advance(hours: 1)
        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        #expect(WidgetSnapshot.load(defaults: defaults)?.updatedAt == snapshot.updatedAt)
        let snack = Nutrients(kcal: 100, proteinG: 0, carbsG: 0, fatG: 0)
        try #require(env.diary).logQuickAdd(name: nil, nutrients: snack, slotID: "lunch", day: env.today)
        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        #expect(WidgetSnapshot.load(defaults: defaults)?.kcal == 740)
        #expect(WidgetSnapshot.load(defaults: UserDefaults(suiteName: "widget-empty-\(UUID().uuidString)")) == nil)
    }

    @Test func `widget hydration counts every drink against the weight-based goal`() throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let suite = "widget-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try #require(env.water).add(ml: 500, day: env.today)
        let cola = try #require(env.foods).save(FoodDetail(food: Food(
            name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0), isLiquid: true,
        ))).food
        _ = try #require(env.diary).log(food: cola, quantity: .base(330), slotID: "snacks", day: env.today)
        let metrics = try #require(env.dailyMetrics)
        try metrics.upsert([
            DailyHealthMetrics(day: env.today.adding(days: -3), weightKg: 80, waterMl: 100),
            DailyHealthMetrics(day: env.today, waterMl: 250),
        ])
        try metrics.setWeightTrends([env.today.adding(days: -3): 80]) // an older weight still sets today's goal

        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        let snapshot = try #require(WidgetSnapshot.load(defaults: defaults))
        #expect(snapshot.waterMl == 1080 && snapshot.waterGoalMl == 2400)
    }

    @Test func `backups are off without a folder and weekly with one`() async throws {
        #expect(AppEnvironment.preview(clock: clock.appClock).backups == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("app-backups-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = AppEnvironment.preview(clock: clock.appClock, backupsDirectory: dir)
        let backups = try #require(env.backups)
        env.backupIfDue()
        // The backup runs in a detached low-priority task: give a busy CI runner time to get to it.
        #expect(await waitUntil(timeout: .seconds(30)) { (try? backups.list().count) == 1 })
        // A second request the same week writes nothing (checked directly: there is no task to wait for).
        #expect(try backups.backupIfDue() == nil)
        #expect(try backups.list().count == 1)
        #expect(DuplicateFoodsView.facts(FoodDetail(food: Food(name: "X", per100: .zero), barcodes: ["1"])) == "Logged 0 times · 1 barcode")
    }
}
