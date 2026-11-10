import Core
import Foundation
import Persistence
import SwiftUI
import Testing
@testable import Nutrilog

// Owner feedback after the second device test (#62–#67, #70): a quieter sleep tile, a step goal with goal-coloured
// bars, water coloured by its goal, one Total energy tile drawn as resting + active, and metric descriptions.

@MainActor
struct DashboardFeedbackTests {
    let today = LocalDay("2026-11-09")!

    private func snapshot(_ metrics: DailyHealthMetrics, stepGoal: Int = StepGoal.defaultSteps) -> DashboardSnapshot {
        var data = DashboardData(today: today)
        data.metrics = [DailyMetricsRecord(metrics, fetchedAt: Date())]
        data.stepGoal = stepGoal
        return DashboardSnapshot(data)
    }

    // MARK: Sleep (#62)

    @Test func `the sleep tile speaks the time asleep only`() {
        let night = DailyHealthMetrics(
            day: today, sleepAsleepMin: 450, sleepInBedMin: 480, sleepCoreMin: 240, sleepDeepMin: 90, sleepRemMin: 120, sleepAwakeMin: 30,
        )
        let snapshot = snapshot(night)
        #expect(snapshot.accessibilityLabel(of: .sleep, state: .ready) == "Sleep, 7 hours 30 minutes asleep")
        #expect(snapshot.sparkline(for: .sleep) == nil)
        #expect(snapshot.accessibilityTrend(of: .sleep, state: .ready) == nil)
        // The stages stay in the detail list.
        var data = DashboardData(today: today)
        data.metrics = [DailyMetricsRecord(night, fetchedAt: Date())]
        let row = TileHistory.rows(for: .sleep, data: data).first
        #expect(row?.detail?.contains("Deep") == true)
        // Only time in bed known: that is what the tile says.
        let inBedOnly = self.snapshot(DailyHealthMetrics(day: today, sleepInBedMin: 480))
        #expect(inBedOnly.accessibilityLabel(of: .sleep, state: .ready) == "Sleep, 8 hours in bed")
        #expect(!DashboardTile.sleep.isWide)
    }

    // MARK: Step goal (#63)

    @Test func `steps are banded by the goal`() {
        #expect(StepGoal.band(steps: 10000, goal: 10000) == .reached)
        #expect(StepGoal.band(steps: 14000, goal: 10000) == .reached)
        #expect(StepGoal.band(steps: 9999, goal: 10000) == .near)
        #expect(StepGoal.band(steps: 8000, goal: 10000) == .near)
        #expect(StepGoal.band(steps: 7999, goal: 10000) == .far)
        #expect(StepGoal.band(steps: 0, goal: 10000) == .far)
        #expect(GoalColor.steps(12000, goal: 10000) == GoalColor.reached)
        #expect(GoalColor.steps(9000, goal: 10000) == GoalColor.near)
        #expect(GoalColor.steps(3000, goal: 10000) == GoalColor.missed)
    }

    @Test func `the step goal is saved in settings and reaches the dashboard`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(StepGoal.load(from: profiles) == 10000)
        try StepGoal.save(7500, to: profiles)
        #expect(StepGoal.load(from: profiles) == 7500)
        try StepGoal.save(10, to: profiles) // out of range: clamped
        #expect(StepGoal.load(from: profiles) == StepGoal.validRange.lowerBound)
        try StepGoal.save(8000, to: profiles)
        let model = DashboardModel(environment: env)
        #expect(model.snapshot.stepGoal == 8000)
        try StepGoal.save(6000, to: profiles)
        model.reloadSettings()
        #expect(model.snapshot.stepGoal == 6000)
    }

    @Test func `step bars and the spoken label follow the goal`() {
        let snapshot = snapshot(DailyHealthMetrics(day: today, steps: 8500), stepGoal: 10000)
        #expect(snapshot.goalColor(of: .steps, value: 10000) == GoalColor.reached)
        #expect(snapshot.goalColor(of: .steps, value: 8500) == GoalColor.near)
        #expect(snapshot.goalColor(of: .steps, value: 2000) == GoalColor.missed)
        #expect(snapshot.goalColor(of: .weight, value: 80) == nil)
        #expect(snapshot.accessibilityLabel(of: .steps, state: .ready) == "Steps, 8,500 steps, close to the goal of 10,000")
        let reached = self.snapshot(DailyHealthMetrics(day: today, steps: 8500), stepGoal: 8000)
        #expect(reached.accessibilityLabel(of: .steps, state: .ready) == "Steps, 8,500 steps, goal of 8,000 reached")
    }

    // MARK: Water (#64)

    @Test func `water is red below its goal and green from it`() {
        #expect(GoalColor.water(2499, goalMl: 2500) == GoalColor.missed)
        #expect(GoalColor.water(2500, goalMl: 2500) == GoalColor.reached)
        #expect(GoalColor.water(3000, goalMl: 2500) == GoalColor.reached)
        var data = DashboardData(today: today)
        data.waterGoalMl = 2000
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, waterMl: 2100), fetchedAt: Date())]
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot.goalColor(of: .water, value: 1500) == GoalColor.missed)
        #expect(snapshot.goalColor(of: .water, value: 2000) == GoalColor.reached)
        #expect(snapshot.accessibilityLabel(of: .water, state: .ready) == "Water, 2,100 of 2,000 millilitres, goal reached")
    }

    // MARK: Total energy (#66)

    @Test func `there is one energy-burned tile and chart`() {
        #expect(DashboardTile.allCases.map(\.title).count { $0.localizedCaseInsensitiveContains("energy") } == 1)
        #expect(DashboardTile.totalEnergy.title == "Total energy")
        #expect(ChartMetric(tile: .totalEnergy) == .totalEnergy)
        #expect(ChartMetric.totalEnergy.title == "Total energy")
        #expect(!ChartMetric.allCases.contains { $0.rawValue == "activeEnergy" })
    }

    @Test func `total energy bars are resting plus active`() {
        // Monday to Wednesday of one week.
        let stats = [
            DayStats(day: today, activeKcal: 400, basalKcal: 1600),
            DayStats(day: today.adding(days: 1), activeKcal: 500), // only one part: no bar
            DayStats(day: today.adding(days: 2), activeKcal: 600, basalKcal: 1700),
        ]
        let series = ChartBuilder.series(.totalEnergy, range: .week, stats: stats, unit: .kcal)
        #expect(series.points.map(\.value) == [2000, nil, 2300])
        #expect(series.points.map(\.resting) == [1600, nil, 1700])
        #expect(series.points.map(\.active) == [400, nil, 600])
        #expect(series.average == 2150)
        // In kilojoules the parts still add up to the bar.
        let kilojoules = ChartBuilder.series(.totalEnergy, range: .week, stats: stats, unit: .kilojoules).points[0]
        #expect(abs((kilojoules.resting ?? 0) + (kilojoules.active ?? 0) - (kilojoules.value ?? -1)) < 0.001)
        // Weekly bars: the means of the parts add up to the mean of the totals.
        let weekly = ChartBuilder.weekly(series.points, firstWeekday: 2)
        #expect(weekly.count == 1)
        #expect(weekly[0].value == 2150 && weekly[0].resting == 1650 && weekly[0].active == 500)
    }

    // MARK: Descriptions (#67)

    @Test func `HRV and resting heart rate details describe the metric`() throws {
        for tile in [DashboardTile.hrv, .restingHeartRate] {
            let text = try #require(tile.detailDescription)
            #expect(!text.contains("Days without a value"))
            #expect(text.contains("average"))
        }
        #expect(DashboardTile.hrv.detailDescription?.contains("Heart rate variability") == true)
        #expect(DashboardTile.restingHeartRate.detailDescription?.contains("beats per minute") == true)
        #expect(DashboardTile.steps.detailDescription?.contains("Apple Health") == true)
        #expect(DashboardTile.water.detailDescription == nil)
    }
}
