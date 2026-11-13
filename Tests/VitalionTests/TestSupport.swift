import Core
import Foundation
import HealthKitClient
import Persistence
import Synchronization
import Testing
@testable import Vitalion

/// A clock that tests move forward by hand.
final class ManualClock: Sendable {
    private let date: Mutex<Date>

    /// Starts at local noon of `day`, so whole-day steps never land on a midnight boundary.
    init(day: String = "2026-11-09") {
        let midnight = LocalDay(day)?.startDate() ?? Date(timeIntervalSinceReferenceDate: 0)
        date = Mutex(midnight.addingTimeInterval(12 * 3600))
    }

    var appClock: AppClock {
        AppClock { [self] in date.withLock { $0 } }
    }

    func advance(hours: Double) {
        date.withLock { $0 = $0.addingTimeInterval(hours * 3600) }
    }
}

/// Waits (up to `timeout`) until `condition` holds — for values delivered by database observations.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Fills an environment with `days` of history ending yesterday: three quick-adds a day adding up to `kcal`, and a
/// morning weigh-in that follows the energy balance for a true expenditure of `tdee`.
@MainActor
func seedHistory(_ env: AppEnvironment, days: Int = 45, kcal: Double = 2000, tdee: Double = 2500, startKg: Double = 85) throws {
    let diary = try #require(env.diary), weights = try #require(env.weights)
    var weight = startKg
    for index in 0 ..< days {
        let day = env.today.adding(days: index - days)
        for slot in ["breakfast", "lunch", "dinner"] {
            try diary.logQuickAdd(
                name: nil,
                nutrients: Nutrients(kcal: kcal / 3, proteinG: 30, carbsG: 60, fatG: 20),
                slotID: slot,
                day: day,
            )
        }
        try weights.add(kg: weight, measuredAt: day.startDate().addingTimeInterval(7 * 3600))
        weight += (kcal - tdee) / Energy.kcalPerKg
    }
}

@MainActor
func completeProfile(_ env: AppEnvironment, goal: GoalMode = .lose, rate: Double = 0.5) throws {
    let profiles = try #require(env.profiles)
    var profile = try profiles.profile()
    profile.heightCm = 180
    profile.birthDate = LocalDay("1990-05-01")
    profile.sex = .male
    profile.activityLevel = .moderate
    profile.goalMode = goal
    profile.goalRateKgPerWeek = rate
    try profiles.save(profile)
}

/// The dashboard of `today` with these days of Health metrics; `configure` sets the rest of the data (goals, drinks, …).
func dashboardSnapshot(
    today: LocalDay, metrics: [DailyHealthMetrics] = [], configure: (inout DashboardData) -> Void = { _ in },
) -> DashboardSnapshot {
    var data = DashboardData(today: today)
    data.metrics = metrics.map { DailyMetricsRecord($0, fetchedAt: Date()) }
    configure(&data)
    return DashboardSnapshot(data)
}

/// An environment on `clock` whose fake Health has `days` of demo data ending today; `authorized` says whether the
/// user was already asked for access.
@MainActor
func makeHealthEnvironment(
    clock: ManualClock, days: Int = 120, authorized: Bool = false, observer: FakeHealthObserver? = nil,
) -> (AppEnvironment, FakeHealthDataSource) {
    let fake = FakeHealthDataSource.demo(endingOn: LocalDay.today(now: clock.appClock.now()), days: days)
    fake.update { $0.authorizationRequested = authorized }
    return (AppEnvironment.preview(clock: clock.appClock, health: fake, healthObserver: observer), fake)
}
