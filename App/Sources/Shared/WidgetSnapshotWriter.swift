import Core
import Foundation
import Persistence
import WidgetKit

/// Writes today's numbers for the widgets and asks WidgetKit to reload them (backlog #42).
@MainActor
enum WidgetSnapshotWriter {
    /// The snapshot of `environment.today`; nil when the database is not available.
    static func make(from environment: AppEnvironment) -> WidgetSnapshot? {
        guard let diary = environment.diary, let profiles = environment.profiles else { return nil }
        let today = environment.today
        let totals = (try? diary.totals(for: today)) ?? .zero
        let target = try? profiles.target(on: today)
        let metrics = try? environment.dailyMetrics?.metrics(on: today)?.metrics
        // Hydration: every drink plus other apps' water against the day's goal, as on the Today tile.
        let hydration = try? WaterProgress.read(on: today, environment: environment)
        let weights = (try? StatsLoader.dayWeights(through: today, environment: environment)) ?? []
        return WidgetSnapshot(
            day: today.isoString, kcal: totals.kcal, targetKcal: target?.kcal,
            proteinG: totals.proteinG, carbsG: totals.carbsG, fatG: totals.fatG,
            targetProteinG: target?.proteinG, targetCarbsG: target?.carbsG, targetFatG: target?.fatG,
            steps: metrics?.steps, sleepMin: metrics?.sleepAsleepMin ?? metrics?.sleepInBedMin,
            weightKg: WeightTrend.summary(weights, today: today)?.latestKg,
            waterMl: hydration?.totalMl ?? 0,
            waterGoalMl: hydration?.goalMl ?? HydrationGoal.fallbackMl,
            energyUnit: environment.energyUnit.rawValue, updatedAt: environment.clock.now(),
        )
    }

    /// Saves the snapshot when it differs from the stored one (ignoring the timestamp) and reloads the widgets.
    static func write(from environment: AppEnvironment, defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshot.appGroup)) {
        guard let snapshot = make(from: environment) else { return }
        if var stored = WidgetSnapshot.load(defaults: defaults) {
            stored.updatedAt = snapshot.updatedAt
            if stored == snapshot {
                return
            }
        }
        snapshot.save(defaults: defaults)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Keeps the snapshot current while the app runs: rewrites it whenever today's diary, drinks, target or Health
    /// values change. Runs until cancelled.
    static func keepCurrent(environment: AppEnvironment) async {
        let today = environment.today
        write(from: environment)
        await withDiscardingTaskGroup { group in
            group.addTask { await followDiary(environment, today) }
            group.addTask { await followHydration(environment, today) }
            group.addTask { await followTarget(environment, today) }
            group.addTask { await followMetrics(environment, today) }
        }
    }

    private static func followDiary(_ environment: AppEnvironment, _ day: LocalDay) async {
        guard let repo = environment.diary else { return }
        await DiaryModel.resubscribing { repo.observeDiary(for: day) } onValue: { _ in write(from: environment) } onError: { _ in }
    }

    /// Water, diary drinks and caffeine drinks: the hydration total.
    private static func followHydration(_ environment: AppEnvironment, _ day: LocalDay) async {
        guard let repo = environment.hydration else { return }
        await DiaryModel.resubscribing { repo.observeIntakes(in: day ... day) } onValue: { _ in write(from: environment) } onError: { _ in }
    }

    private static func followTarget(_ environment: AppEnvironment, _ day: LocalDay) async {
        guard let repo = environment.profiles else { return }
        await DiaryModel.resubscribing { repo.observeTarget(on: day) } onValue: { _ in write(from: environment) } onError: { _ in }
    }

    private static func followMetrics(_ environment: AppEnvironment, _ day: LocalDay) async {
        guard let repo = environment.dailyMetrics else { return }
        await DiaryModel.resubscribing { repo.observeMetrics(on: day) } onValue: { _ in write(from: environment) } onError: { _ in }
    }
}
