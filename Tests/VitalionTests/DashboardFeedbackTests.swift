import Core
import Foundation
import Persistence
import SwiftUI
import Testing
@testable import Vitalion

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
        #expect(snapshot
            .accessibilityLabel(of: .sleep, state: .ready, locale: .dashboardEnglish) ==
            "Sleep, 7 hours 30 minutes asleep, close to the goal of 8 hours")
        // Only time in bed known: that is what the tile says.
        let inBedOnly = self.snapshot(DailyHealthMetrics(day: today, sleepInBedMin: 480))
        #expect(inBedOnly
            .accessibilityLabel(of: .sleep, state: .ready, locale: .dashboardEnglish) ==
            "Sleep, 8 hours in bed, goal of 8 hours reached, 1-day streak")
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
        #expect(snapshot
            .accessibilityLabel(of: .steps, state: .ready, locale: .dashboardEnglish) == "Steps, 8,500 steps, close to the goal of 10,000")
        let reached = self.snapshot(DailyHealthMetrics(day: today, steps: 8500), stepGoal: 8000)
        #expect(reached
            .accessibilityLabel(of: .steps, state: .ready, locale: .dashboardEnglish) ==
            "Steps, 8,500 steps, goal of 8,000 reached, 1-day streak")
        // Numbers are grouped for the locale (the test runner speaks English, so the words stay English).
        #expect(snapshot.accessibilityLabel(of: .steps, state: .ready, locale: Locale(identifier: "hr_HR"))
            == "Steps, 8.500 steps, close to the goal of 10.000")
    }

    // MARK: Active energy goal

    @Test func `active energy is banded by its goal`() {
        #expect(ActiveEnergyGoal.band(kcal: 500, goal: 500) == .reached)
        #expect(ActiveEnergyGoal.band(kcal: 800, goal: 500) == .reached)
        #expect(ActiveEnergyGoal.band(kcal: 499, goal: 500) == .near)
        #expect(ActiveEnergyGoal.band(kcal: 400, goal: 500) == .near)
        #expect(ActiveEnergyGoal.band(kcal: 399, goal: 500) == .far)
        #expect(ActiveEnergyGoal.band(kcal: 0, goal: 500) == .far)
        #expect(GoalColor.activeEnergy(kcal: 600, goal: 500) == GoalColor.reached)
        #expect(GoalColor.activeEnergy(kcal: 450, goal: 500) == GoalColor.near)
        #expect(GoalColor.activeEnergy(kcal: 100, goal: 500) == GoalColor.missed)
    }

    @Test func `the active energy goal is saved, clamped and picked up by the dashboard`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(ActiveEnergyGoal.load(from: profiles) == 500)
        try ActiveEnergyGoal.save(650, to: profiles)
        #expect(ActiveEnergyGoal.load(from: profiles) == 650)
        try ActiveEnergyGoal.save(10, to: profiles) // out of range: clamped
        #expect(ActiveEnergyGoal.load(from: profiles) == ActiveEnergyGoal.validRange.lowerBound)
        try ActiveEnergyGoal.save(700, to: profiles)
        let model = DashboardModel(environment: env)
        #expect(model.snapshot.activeEnergyGoalKcal == 700)
        try ActiveEnergyGoal.save(300, to: profiles)
        model.reloadSettings()
        #expect(model.snapshot.activeEnergyGoalKcal == 300)
    }

    @Test func `total energy bars are coloured by the active part only`() throws {
        var data = DashboardData(today: today)
        data.activeEnergyGoalKcal = 400
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, activeKcal: 300, basalKcal: 1700), fetchedAt: Date())]
        let snapshot = DashboardSnapshot(data)
        let point = try #require(snapshot.sparklines[.totalEnergy]?.points.last)
        #expect(point.upper == 300)
        // 2,000 kcal in total, but 300 active of a 400 goal: red, not green.
        #expect(snapshot.goalColor(of: .totalEnergy, value: point.upper) == GoalColor.missed)
        #expect(snapshot
            .accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish) ==
            "Total energy, 2,000 calories, active 300, below the active goal of 400, resting 1,700")
        // In kilojoules the goal is spoken in kilojoules too.
        #expect(snapshot.accessibilityLabel(of: .totalEnergy, state: .ready, energyUnit: .kilojoules, locale: .dashboardEnglish)
            .contains("below the active goal of 1,674"))
    }

    // MARK: Water (#64)

    @Test func `water is red far below its goal, orange close to it and green from it`() {
        #expect(GoalColor.water(1999, goalMl: 2500) == GoalColor.missed)
        #expect(GoalColor.water(2000, goalMl: 2500) == GoalColor.near)
        #expect(GoalColor.water(2499, goalMl: 2500) == GoalColor.near)
        #expect(GoalColor.water(2500, goalMl: 2500) == GoalColor.reached)
        #expect(GoalColor.water(3000, goalMl: 2500) == GoalColor.reached)
        var data = DashboardData(today: today)
        data.waterGoalMode = .fixed
        data.waterGoalMl = 2000
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, waterMl: 2100), fetchedAt: Date())]
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot.goalColor(of: .water, value: 1500) == GoalColor.missed)
        #expect(snapshot.goalColor(of: .water, value: 2000) == GoalColor.reached)
        #expect(snapshot
            .accessibilityLabel(of: .water, state: .ready, locale: .dashboardEnglish) ==
            "Hydration, 2,100 of 2,000 millilitres, goal reached, 1-day streak")
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

    // MARK: Sleep goal, weight, baselines (#72–#74)

    @Test func `sleep is written plainly and coloured by the sleep goal`() throws {
        #expect(DashboardFormat.duration(425) == "7h 5min")
        #expect(DashboardFormat.duration(480) == "8h")
        #expect(DashboardFormat.duration(45) == "45min")
        // Green at the goal, orange up to an hour short, red further below.
        #expect(SleepGoal.band(minutes: 480, goal: 480) == .reached)
        #expect(SleepGoal.band(minutes: 479, goal: 480) == .near)
        #expect(SleepGoal.band(minutes: 420, goal: 480) == .near)
        #expect(SleepGoal.band(minutes: 419, goal: 480) == .far)
        #expect(GoalColor.sleep(minutes: 500, goal: 480) == GoalColor.reached)
        #expect(GoalColor.sleep(minutes: 450, goal: 480) == GoalColor.near)
        #expect(GoalColor.sleep(minutes: 300, goal: 480) == GoalColor.missed)

        // The goal is a setting the dashboard picks up.
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(SleepGoal.load(from: profiles) == 480)
        try SleepGoal.save(435, to: profiles)
        #expect(SleepGoal.load(from: profiles) == 435)
        try SleepGoal.save(10, to: profiles) // out of range: clamped
        #expect(SleepGoal.load(from: profiles) == SleepGoal.validRange.lowerBound)
        try SleepGoal.save(420, to: profiles)
        let model = DashboardModel(environment: env)
        #expect(model.snapshot.sleepGoalMin == 420)

        // The 7-day bars are back, coloured like the value.
        var data = DashboardData(today: today)
        data.sleepGoalMin = 450
        data.metrics = [0: 460, 1: 400, 2: 380].map { offset, minutes in
            DailyMetricsRecord(DailyHealthMetrics(day: today.adding(days: -offset), sleepAsleepMin: minutes), fetchedAt: Date())
        }
        let snapshot = DashboardSnapshot(data)
        let bars = try #require(snapshot.sparkline(for: .sleep))
        #expect(bars.mark == .bar)
        #expect(bars.points.map(\.value).sorted() == [380, 400, 460])
        #expect(snapshot.goalColor(of: .sleep, value: 460) == GoalColor.reached)
        #expect(snapshot.goalColor(of: .sleep, value: 400) == GoalColor.near)
        #expect(snapshot.goalColor(of: .sleep, value: 380) == GoalColor.missed)
        let label = snapshot.accessibilityLabel(of: .sleep, state: .ready, locale: .dashboardEnglish)
        #expect(label == "Sleep, 7 hours 40 minutes asleep, goal of 7 hours 30 minutes reached, 1-day streak")
    }

    @Test func `the weight tile says the weight only`() {
        var data = DashboardData(today: today)
        data.metrics = (0 ..< 10).map {
            DailyMetricsRecord(DailyHealthMetrics(day: today.adding(days: -$0), weightKg: 80 + Double($0) / 10), fetchedAt: Date())
        }
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot
            .accessibilityLabel(of: .weight, state: .ready, locale: .dashboardEnglish) ==
            "Weight, 80.0 kilograms, below the weekly average")
        #expect(snapshot.sparkline(for: .weight) != nil)
    }

    @Test func `HRV and resting heart rate are coloured against the 30-day average`() {
        func comparison(_ value: Double, average30: Double?) -> BaselineComparison {
            BaselineComparison(day: today, value: value, average7: value, average30: average30)
        }
        // HRV: higher is better.
        #expect(BaselineBand.hrv(comparison(55, average30: 50)) == .reached)
        #expect(BaselineBand.hrv(comparison(50, average30: 50)) == .reached)
        #expect(BaselineBand.hrv(comparison(47, average30: 50)) == .near)
        #expect(BaselineBand.hrv(comparison(45, average30: 50)) == .near)
        #expect(BaselineBand.hrv(comparison(44, average30: 50)) == .far)
        #expect(BaselineBand.hrv(comparison(44, average30: nil)) == nil)
        // Resting heart rate: lower is better.
        #expect(BaselineBand.restingHR(comparison(56, average30: 60)) == .reached)
        #expect(BaselineBand.restingHR(comparison(60, average30: 60)) == .reached)
        #expect(BaselineBand.restingHR(comparison(62, average30: 60)) == .near)
        #expect(BaselineBand.restingHR(comparison(63, average30: 60)) == .near)
        #expect(BaselineBand.restingHR(comparison(64, average30: 60)) == .far)

        // On the snapshot: 30 days at 50 ms / 60 bpm, today 40 ms / 61 bpm.
        var data = DashboardData(today: today)
        data.metrics = (0 ... 30).map {
            let metrics = DailyHealthMetrics(day: today.adding(days: -$0), restingHR: $0 == 0 ? 61 : 60, hrvSDNNms: $0 == 0 ? 40 : 50)
            return DailyMetricsRecord(metrics, fetchedAt: Date())
        }
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot.baselineColor(of: .hrv) == GoalColor.missed)
        #expect(snapshot.baselineColor(of: .restingHeartRate) == GoalColor.near)
        #expect(snapshot.baselineColor(of: .steps) == nil)
        #expect(snapshot.accessibilityLabel(of: .restingHeartRate, state: .ready, locale: .dashboardEnglish)
            .contains("2% above your 30-day average"))
        // No baseline yet: no colour.
        var short = DashboardData(today: today)
        short.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, hrvSDNNms: 40), fetchedAt: Date())]
        #expect(DashboardSnapshot(short).baselineColor(of: .hrv) == nil)
    }

    // MARK: Weight and body fat against the week before

    @Test func `weight is coloured by the goal against the weekly average, body fat by being below it`() {
        /// 7 days at 80 kg / 20 %, today as given.
        func snapshot(kg: Double, fat: Double, goal: GoalMode, days: Int = 7) -> DashboardSnapshot {
            var data = DashboardData(today: today)
            data.goalMode = goal
            data.metrics = (0 ... days).map {
                let metrics = DailyHealthMetrics(day: today.adding(days: -$0), weightKg: $0 == 0 ? kg : 80, bodyFatPct: $0 == 0 ? fat : 20)
                return DailyMetricsRecord(metrics, fetchedAt: Date())
            }
            return DashboardSnapshot(data)
        }
        // Losing: below the average is green, slightly above orange, far above red.
        #expect(snapshot(kg: 79.6, fat: 19.8, goal: .lose).weeklyBand(of: .weight) == .reached)
        #expect(snapshot(kg: 80.4, fat: 19.8, goal: .lose).weeklyBand(of: .weight) == .near)
        #expect(snapshot(kg: 80.8, fat: 19.8, goal: .lose).weeklyBand(of: .weight) == .far)
        // Gaining: the mirror image.
        #expect(snapshot(kg: 80.4, fat: 20, goal: .gain).weeklyBand(of: .weight) == .reached)
        #expect(snapshot(kg: 79.6, fat: 20, goal: .gain).weeklyBand(of: .weight) == .near)
        #expect(snapshot(kg: 79.2, fat: 20, goal: .gain).weeklyBand(of: .weight) == .far)
        // Maintaining: no colour.
        #expect(snapshot(kg: 82, fat: 20, goal: .maintain).weeklyBand(of: .weight) == nil)
        #expect(snapshot(kg: 82, fat: 20, goal: .maintain).baselineColor(of: .weight) == nil)
        // Body fat does not depend on the goal.
        #expect(snapshot(kg: 80, fat: 19.5, goal: .maintain).baselineColor(of: .bodyFat) == GoalColor.reached)
        #expect(snapshot(kg: 80, fat: 20.4, goal: .maintain).baselineColor(of: .bodyFat) == GoalColor.near)
        #expect(snapshot(kg: 80, fat: 20.8, goal: .maintain).baselineColor(of: .bodyFat) == GoalColor.missed)
        // Too little history for a weekly average: no colour.
        let short = snapshot(kg: 82, fat: 22, goal: .lose, days: 2)
        #expect(short.weeklyWeightKg == nil && short.baselineColor(of: .weight) == nil && short.baselineColor(of: .bodyFat) == nil)
        // VoiceOver says what the colour means.
        #expect(snapshot(kg: 80.8, fat: 19.5, goal: .lose).accessibilityLabel(of: .weight, state: .ready, locale: .dashboardEnglish)
            == "Weight, 80.8 kilograms, above the weekly average")
        #expect(snapshot(kg: 80.8, fat: 19.5, goal: .lose).accessibilityLabel(of: .bodyFat, state: .ready, locale: .dashboardEnglish)
            == "Body fat, 19.5 percent, below the weekly average")
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
