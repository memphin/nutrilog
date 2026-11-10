import Core
import Foundation
import Persistence

/// The adaptive maintenance estimate with what it was computed from and what it proposes (FR-34, backlog #34, #35).
struct ExpenditureSnapshot: Equatable {
    /// The day the snapshot was computed on; the estimate's window ends the day before.
    var today: LocalDay
    var estimate: Result<TDEEEstimate, TDEEUnavailable>
    /// Mifflin-St Jeor × activity; nil while the profile or a weight is missing.
    var baselineKcal: Double?
    var profile: Profile
    /// The target in effect today.
    var currentTarget: Target?
    /// The check-in's proposed target; nil without an estimate.
    var proposal: TargetProposal?
    var lastCheckIn: CheckInRecord?

    /// The estimate's value, if there is one.
    var kcal: Double? {
        try? estimate.get().kcal
    }

    /// The goal as a signed weekly weight change: −0.5 for "lose 0.5 kg/week".
    var goalChangeKgPerWeek: Double {
        profile.goalMode.sign * abs(profile.goalRateKgPerWeek)
    }

    var isCheckInDue: Bool {
        CheckInSchedule.isDue(today: today, weekday: profile.checkinWeekday, lastCheckIn: lastCheckIn?.computedForDay)
    }
}

@MainActor
enum Expenditure {
    /// Days of history handed to the estimator (the window is 14; confidence looks 21 back).
    static let historyDays = 60

    /// The estimate as of `environment.today`: the window ends yesterday (today is still being logged), the previous
    /// estimate is the last check-in's before today.
    static func snapshot(environment: AppEnvironment, calendar: Calendar = .current) throws -> ExpenditureSnapshot? {
        guard let profiles = environment.profiles, let checkIns = environment.checkIns else { return nil }
        let today = environment.today
        let endDay = today.previous
        let stats = try StatsLoader.load(endDay.adding(days: -(historyDays - 1)) ... endDay, environment: environment, calendar: calendar)
        let profile = try profiles.profile()
        let target = try profiles.target(on: today)
        let baseline = baseline(profile: profile, weightKg: stats.last?.trendKg ?? stats.last { $0.weightKg != nil }?.weightKg, on: today)
        let estimate = try AdaptiveTDEE.estimate(
            history: history(stats), endDay: endDay, baselineKcal: baseline,
            previousKcal: checkIns.previousEstimateKcal(before: today),
        )
        let proposal = (try? estimate.get()).map {
            AdaptiveTDEE.proposal(
                for: $0,
                goal: profile.goalMode,
                rateKgPerWeek: profile.goalRateKgPerWeek,
                currentTargetKcal: target?.kcal,
            )
        }
        return try ExpenditureSnapshot(
            today: today, estimate: estimate, baselineKcal: baseline, profile: profile, currentTarget: target,
            proposal: proposal, lastCheckIn: checkIns.latest(),
        )
    }

    static func history(_ stats: [DayStats]) -> [TDEEDay] {
        stats.map { day in
            TDEEDay(
                day: day.day, kcalIn: day.kcal ?? 0, entryCount: day.entryCount, isComplete: day.isComplete,
                weightKg: day.weightKg, trendKg: day.trendKg,
            )
        }
    }

    /// Formula maintenance (FR-31) for the profile at `weightKg`; nil when something is missing.
    static func baseline(profile: Profile, weightKg: Double?, on day: LocalDay) -> Double? {
        guard let weightKg, let height = profile.heightCm, let birth = profile.birthDate, let sex = profile.sex else { return nil }
        let bmr = Energy.mifflinStJeor(
            weightKg: weightKg, heightCm: height, ageYears: Double(Energy.age(birthDate: birth, on: day)), sex: sex,
        )
        return Energy.baselineTDEE(bmr: bmr, activity: profile.activityLevel)
    }
}
