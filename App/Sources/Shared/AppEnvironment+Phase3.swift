import Core
import Foundation
import Persistence

/// The app's tabs.
enum AppTab: String, Hashable, CaseIterable {
    case today, diary, trends, foods, settings
}

extension AppEnvironment {
    /// The environment of the running app, for code the system starts outside the view tree (App Intents).
    /// Set once by `NutrilogApp`.
    static var shared: AppEnvironment?

    var recipes: RecipeRepository? {
        db.map { RecipeRepository($0, clock: clock) }
    }

    /// Saved meals (FR-24).
    var meals: MealTemplateRepository? {
        db.map { MealTemplateRepository($0, clock: clock) }
    }

    /// Weekly check-ins (SPEC §5.4.1).
    var checkIns: CheckInRepository? {
        db.map { CheckInRepository($0, clock: clock) }
    }

    /// Automatic local backups (FR-62); nil when they are off or the database could not be opened.
    var backups: LocalBackups? {
        guard let portability, let backupsDirectory else { return nil }
        return LocalBackups(directory: backupsDirectory, portability: portability, clock: clock)
    }

    /// Shows `day` in the Diary tab.
    func openDiary(on day: LocalDay) {
        diaryDayRequest = day
        selectedTab = .diary
    }

    /// Recomputes the weight trend from every known weight and stores it in `daily_metrics.weight_trend_kg`
    /// (backlog #33). Cheap; called after Health syncs and weight changes. Failures are ignored: the stored trend is
    /// a cache for sync, every screen computes its own from the weights.
    func refreshStoredWeightTrend() {
        guard let dailyMetrics else { return }
        do {
            let weights = try StatsLoader.dayWeights(through: today, environment: self)
            try dailyMetrics.setWeightTrends(WeightTrend.trendByDay(WeightTrend.samples(weights), through: today))
        } catch {
            // Recomputed on the next refresh.
        }
    }

    /// Writes the weekly local backup when one is due. Runs off the main actor; best effort.
    func backupIfDue() {
        guard let backups else { return }
        Task.detached(priority: .utility) {
            _ = try? backups.backupIfDue()
        }
    }

    /// Work that follows any change to what the widgets show (a logged entry, water, a new target).
    func widgetDataDidChange() {
        WidgetSnapshotWriter.write(from: self)
    }
}
