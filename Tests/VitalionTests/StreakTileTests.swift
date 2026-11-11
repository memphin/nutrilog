import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

// Streaks on the Steps, Water and Sleep tiles: days in a row the goal was reached.

@MainActor
struct StreakTileTests {
    let today = LocalDay("2026-11-11")!

    func record(_ offset: Int, steps: Int? = nil, sleep: Int? = nil, inBed: Int? = nil, water: Double? = nil) -> DailyMetricsRecord {
        DailyMetricsRecord(
            DailyHealthMetrics(
                day: today.adding(days: -offset), steps: steps, sleepAsleepMin: sleep, sleepInBedMin: inBed, waterMl: water,
            ),
            fetchedAt: Date(),
        )
    }

    @Test func `steps streak counts days at or above the goal`() {
        var data = DashboardData(today: today)
        data.stepGoal = 8000
        // Today not there yet; three days before it at the goal, then a short day.
        data.metrics = [record(0, steps: 3000), record(1, steps: 8000), record(2, steps: 12000), record(3, steps: 9000), record(4, steps: 7999)]
        let streak = DashboardSnapshot(data).streak(for: .steps)
        #expect(streak == Streak(days: 3, includesToday: false, isAtLimit: false))
    }

    @Test func `sleep streak uses time in bed when that is all there is`() {
        var data = DashboardData(today: today)
        data.sleepGoalMin = 420
        data.metrics = [record(0, sleep: 430), record(1, inBed: 480), record(2, sleep: 400, inBed: 500)]
        // Night 2: asleep counts over in bed, and 400 min is short of the goal.
        #expect(DashboardSnapshot(data).streak(for: .sleep) == Streak(days: 2, includesToday: true, isAtLimit: false))
    }

    @Test func `water streak adds Vitalion's water to other apps'`() {
        var data = DashboardData(today: today)
        data.waterGoalMl = 2000
        data.metrics = [record(1, water: 1000), record(2, water: 2000)]
        data.waterByDay = [today: 2000, today.adding(days: -1): 1000, today.adding(days: -3): 1500]
        let streak = DashboardSnapshot(data).streak(for: .water)
        #expect(streak == Streak(days: 3, includesToday: true, isAtLimit: false))
    }

    @Test func `streak goes back no further than the loaded history`() {
        var data = DashboardData(today: today)
        data.metrics = (0 ..< 80).map { record($0, steps: 20000) }
        let streak = DashboardSnapshot(data).streak(for: .steps)
        #expect(streak?.days == DashboardData.historyDays)
        #expect(streak?.isAtLimit == true)
    }

    @Test func `only steps, water and sleep have streaks`() {
        let snapshot = DashboardSnapshot(DashboardData(today: today))
        #expect(snapshot.streak(for: .steps) == Streak.none)
        #expect(snapshot.streak(for: .weight) == nil)
        #expect(snapshot.streak(for: .caffeine) == nil)
    }

    @Test func `badge text and spoken text`() {
        #expect(StreakBadge.text(Streak(days: 5, includesToday: true, isAtLimit: false)) == "5")
        #expect(StreakBadge.text(Streak(days: 60, includesToday: false, isAtLimit: true)) == "60+")
        #expect(StreakBadge.spoken(Streak(days: 1, includesToday: true, isAtLimit: false)) == "1-day streak")
        #expect(StreakBadge.spoken(Streak(days: 60, includesToday: true, isAtLimit: true)) == "60-day streak or more")
        #expect(StreakBadge.spoken(.none) == nil)
    }

    @Test func `VoiceOver reads the streak after the value`() {
        var data = DashboardData(today: today)
        data.stepGoal = 5000
        data.metrics = [record(0, steps: 6000), record(1, steps: 6000)]
        let label = DashboardSnapshot(data).accessibilityLabel(of: .steps, state: .ready)
        #expect(label.hasSuffix(", 2-day streak"))
        data.metrics = [record(0, steps: 100)]
        #expect(!DashboardSnapshot(data).accessibilityLabel(of: .steps, state: .ready).contains("streak"))
    }
}
