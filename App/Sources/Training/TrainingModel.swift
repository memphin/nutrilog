import Core
import Foundation
import HealthKitClient
import Observation
import Persistence

/// What the Training tab can show of Apple Health.
enum TrainingAccess: Equatable {
    /// No Health store on this device.
    case unavailable
    /// Health was never connected: offer the onboarding.
    case notConnected
    /// Connected before Vitalion read workouts: Health has to ask for them once.
    case needsWorkoutAccess
    case connected
}

/// This week's eating next to the training: the same numbers as the weekly report (`WeeklyReport`).
struct TrainingFuel: Equatable {
    /// Mean intake of the logged days; nil when nothing is logged yet this week.
    var averageKcal: Double?
    var averageTargetKcal: Double?
    var proteinG: Double?
    /// Protein per kilogram of body weight (the weight trend); nil without a weight.
    var proteinPerKg: Double?
    var trendChangeKg: Double?

    /// - Parameter weightKg: the body weight for protein per kg when the week has no weight trend of its own.
    init(report: WeeklyReport, weightKg: Double?) {
        averageKcal = report.averageIntake?.kcal
        averageTargetKcal = report.averageTargetKcal
        proteinG = report.averageIntake?.proteinG
        trendChangeKg = report.trendChangeKg
        if let protein = proteinG, let weight = report.trendEndKg ?? weightKg, weight > 0 {
            proteinPerKg = protein / weight
        } else {
            proteinPerKg = nil
        }
    }
}

/// State of the Training tab: the workouts Apple Health has, sorted into training and everyday activity
/// (`TrainingOverview`), and this week's fuel. Follows Health syncs, the training days and the kinds that count as
/// training live.
@MainActor
@Observable
final class TrainingModel {
    private let environment: AppEnvironment
    private let calendarProvider: @MainActor () -> Calendar

    private(set) var overview: TrainingOverview?
    private(set) var fuel: TrainingFuel?
    var errorMessage: String?

    @ObservationIgnored private var workouts: [HealthWorkout]?
    @ObservationIgnored private var rules: TrainingRules?
    @ObservationIgnored private var training: TrainingDays?

    init(environment: AppEnvironment, calendar: @escaping @MainActor () -> Calendar = { Calendar.current }) {
        self.environment = environment
        calendarProvider = calendar
    }

    private var firstWeekday: Int {
        calendarProvider().firstWeekday
    }

    var energyUnit: EnergyUnit {
        environment.energyUnit
    }

    /// Follows `HealthSyncService.requestStatus`, so the tab moves on by itself once access was answered.
    var access: TrainingAccess {
        guard environment.health.isAvailable, let sync = environment.healthSync else { return .unavailable }
        guard sync.isConnected else { return .notConnected }
        return sync.requestStatus == .shouldRequest ? .needsWorkoutAccess : .connected
    }

    /// True while a Health sync runs: an empty tab then says "reading" instead of "no workouts".
    var isSyncing: Bool {
        if case .syncing = environment.healthSync?.phase {
            return true
        }
        return false
    }

    /// Streams what the tab shows for `environment.today`; restarted by the view when the day changes.
    func observe() async {
        await environment.healthSync?.reloadAuthorization()
        let today = environment.today
        let firstDay = TrainingOverview.firstDay(today: today, firstWeekday: firstWeekday)
        let week = today.weekStart(firstWeekday: firstWeekday)
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeWorkouts(firstDay ... week.adding(days: 6)) }
            group.addTask { await self.observeRules() }
            group.addTask { await self.observeTraining(week ... week.adding(days: 6)) }
        }
    }

    private func observeWorkouts(_ days: ClosedRange<LocalDay>) async {
        guard let repo = environment.workouts else { return }
        await DiaryModel.resubscribing { repo.observeWorkouts(in: days) } onValue: { workouts in
            self.workouts = workouts
            rebuild()
        } onError: { report($0) }
    }

    private func observeRules() async {
        guard let repo = environment.workouts else { return }
        await DiaryModel.resubscribing { repo.observeRules() } onValue: { rules in
            self.rules = rules
            rebuild()
        } onError: { report($0) }
    }

    private func observeTraining(_ week: ClosedRange<LocalDay>) async {
        guard let repo = environment.trainingDays else { return }
        await DiaryModel.resubscribing { repo.observeTrainingDays(in: week) } onValue: { training in
            self.training = training
            rebuild()
        } onError: { report($0) }
    }

    /// Builds the overview once every part has arrived.
    private func rebuild() {
        guard let workouts, let rules, let training else { return }
        let built = TrainingOverview(
            workouts: workouts, rules: rules, training: training, today: environment.today, firstWeekday: firstWeekday,
        )
        if overview != built {
            overview = built
        }
    }

    /// Re-reads this week's fuel; the view calls it when the tab appears and when the day, the data, the unit or
    /// Health change.
    func reloadFuel() {
        let week = environment.today.weekStart(firstWeekday: firstWeekday)
        guard let report = try? WeeklyReportLoader.load(weekStart: week, environment: environment) else {
            fuel = nil
            return
        }
        let weight = try? environment.dailyMetrics?.weightTrendKg(onOrBefore: environment.today)
        let loaded = TrainingFuel(report: report, weightKg: weight)
        if fuel != loaded {
            fuel = loaded
        }
    }

    /// Pull-to-refresh: re-reads Health.
    func refresh() async {
        await environment.refreshHealth()
        await environment.healthSync?.reloadAuthorization()
        reloadFuel()
    }

    /// "Allow workouts": the Health sheet for the types not answered yet, then a full read.
    func allowWorkouts() async {
        do {
            try await environment.allowNewHealthTypes()
        } catch {
            errorMessage = String(localized: "Couldn't ask Apple Health: \(error.localizedDescription)")
        }
    }

    private func report(_ error: any Error) {
        errorMessage = String(localized: "Couldn't load your workouts: \(error.localizedDescription)")
    }
}
