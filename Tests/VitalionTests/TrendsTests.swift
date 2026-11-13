import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

@MainActor
struct TrendsDataTests {
    let today = LocalDay("2026-11-09")!
    let macros = MacroTargets(proteinG: 100, carbsG: 200, fatG: 60)

    private func summary(_ day: LocalDay, _ kcal: Double, entries: Int = 4, complete: Bool = false) -> DiaryDaySummary {
        let totals = Nutrients(kcal: kcal, proteinG: kcal / 20, carbsG: kcal / 10, fatG: kcal / 30)
        return DiaryDaySummary(day: day, totals: totals, entryCount: entries, isComplete: complete)
    }

    private var targets: EffectiveTimeline<Target> {
        let october = LocalDay("2026-10-01")!, november = LocalDay("2026-11-05")!
        return EffectiveTimeline([
            (from: october, value: Target(effectiveFrom: october, kcal: 2400, macros: macros, origin: .manual)),
            (from: november, value: Target(effectiveFrom: november, kcal: 2000, macros: macros, origin: .adaptive)),
        ])
    }

    @Test func `the calendar colors each day against the target in effect on that day`() throws {
        let months = try HistoryCalendar.build(
            today: today,
            summaries: [
                summary(#require(LocalDay("2026-11-04")), 2400), // on the old target
                summary(#require(LocalDay("2026-11-05")), 2400), // 20 % over the new one
                summary(#require(LocalDay("2026-11-06")), 2200), // +10 %
                summary(#require(LocalDay("2026-11-07")), 2050),
                summary(#require(LocalDay("2026-09-20")), 1800), // before any target
                summary(#require(LocalDay("2026-11-08")), 0, entries: 0, complete: true), // a fasting day marked complete
            ],
            targets: targets, firstWeekday: 2,
        )
        #expect(months.count == 24)
        #expect(try months.first?.start == #require(LocalDay("2024-12-01")))
        let november = months[23]
        #expect(try november.start == #require(LocalDay("2026-11-01")))
        #expect(november.days.count == 30)
        #expect(november.leadingBlanks == 6) // 1 Nov 2026 is a Sunday, weeks start on Monday
        func band(_ day: Int) -> Adherence {
            november.days[day - 1].adherence
        }
        #expect(band(4) == .onTarget)
        #expect(band(5) == .off)
        #expect(band(6) == .near)
        #expect(band(7) == .onTarget)
        #expect(band(8) == .off)
        #expect(band(3) == .notLogged)
        #expect(november.days[9].isFuture && !november.days[8].isFuture)
        // Today counts once it is over or marked as fully logged.
        let open = HistoryCalendar.build(today: today, summaries: [summary(today, 900)], targets: targets, firstWeekday: 2)
        #expect(open[23].days[8].adherence == .notLogged && open[23].days[8].kcal == 900)
        let closed = HistoryCalendar.build(
            today: today,
            summaries: [summary(today, 900, complete: true)],
            targets: targets,
            firstWeekday: 2,
        )
        #expect(closed[23].days[8].adherence == .off)
        #expect(months[21].days[19].adherence == .noTarget)
        #expect(HistoryCalendar.build(today: today, summaries: [], targets: targets, firstWeekday: 1)[23].leadingBlanks == 0)
        #expect(try HistoryCalendar.firstDay(today: today) == #require(LocalDay("2024-12-01")))
    }

    @Test func `building two years of calendar is fast`() {
        let summaries = (0 ..< 730).map { summary(today.adding(days: -$0), 2000 + Double($0 % 7) * 80) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = HistoryCalendar.build(today: today, summaries: summaries, targets: targets, firstWeekday: 2)
        }
        #expect(elapsed < .milliseconds(250))
    }

    private func week() -> [DayStats] {
        let monday = LocalDay("2026-11-02")!
        let kcal: [Double?] = [1900, 2100, nil, 2500, 2000, 2233, 1500]
        var metrics: [DailyHealthMetrics] = []
        for index in 0 ..< 7 {
            let steps: Int? = index == 2 ? nil : 7000 + index * 911
            let asleep: Int? = index == 6 ? nil : 400 + index * 13
            let weight: Double? = index % 2 == 0 ? 80 - Double(index) * 0.1 : nil
            let water: Double? = index == 1 ? 500 : nil
            metrics.append(DailyHealthMetrics(
                day: monday.adding(days: index), steps: steps, activeKcal: 500, basalKcal: index == 0 ? nil : 1700,
                sleepAsleepMin: asleep, sleepInBedMin: 480, weightKg: weight, waterMl: water,
            ))
        }
        var summaries: [DiaryDaySummary] = []
        for (index, value) in kcal.enumerated() {
            if let value {
                summaries.append(summary(monday.adding(days: index), value))
            }
        }
        var weights: [DayWeight] = []
        for row in metrics {
            if let kg = row.weightKg {
                weights.append(DayWeight(day: row.day, kg: kg, bodyFatPct: 20))
            }
        }
        return StatsBuilder.build(
            range: monday ... monday.adding(days: 6), summaries: summaries, targets: targets, metrics: metrics,
            dayWeights: weights, loggedFluidMl: [monday: 1500, monday.next: 1000],
        )
    }

    @Test func `trends count every drink and colour each day by its own hydration goal`() throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let day = env.today.previous
        try #require(env.water).add(ml: 500, day: day)
        let cola = try #require(env.foods).save(FoodDetail(food: Food(
            name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0), isLiquid: true,
        ))).food
        _ = try #require(env.diary).log(food: cola, quantity: .base(330), slotID: "snacks", day: day)
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: day, waterMl: 250)])
        let stats = try StatsLoader.load(day ... env.today, environment: env)
        #expect(stats.map(\.waterMl) == [1080, nil])
        #expect(ChartMetric.water.title == "Hydration")

        // Weight mode: the goal follows the trend of each day; days before the first trend use the fallback.
        let profile = try #require(env.profiles).profile()
        let monday = try #require(LocalDay("2026-11-02"))
        let goals = ChartBuilder.hydrationGoals(
            in: monday ... monday.adding(days: 6), profile: profile, trendsKg: [monday.adding(days: 3): 80, monday.adding(days: 4): 90],
            training: .none,
        )
        #expect(goals[monday] == HydrationGoal.fallbackMl && goals[monday.adding(days: 3)] == 2400)
        #expect(goals[monday.adding(days: 4)] == 2700)
        #expect(ChartBuilder.goal(of: ChartPoint(day: monday.adding(days: 3), spanDays: 1), in: goals) == 2400)
        // A weekly bar: the mean of the days it knows (2500, 2400, 2700, 2500, 2500; two days lie outside).
        let week = ChartPoint(day: monday.adding(days: 2), spanDays: 7)
        #expect(ChartBuilder.goal(of: week, in: goals) == 2520)
        #expect(ChartBuilder.goal(of: ChartPoint(day: monday.adding(days: 20), spanDays: 1), in: goals) == nil)
    }

    @Test func `stats merge the diary, targets, Health and weights per day`() {
        let stats = week()
        #expect(stats.count == 7)
        #expect(stats[0].kcal == 1900)
        #expect(stats[0].targetKcal == 2400 && stats[3].targetKcal == 2000)
        #expect(stats[2].intake == nil && stats[2].adherence == .notLogged)
        #expect(stats[0].waterMl == 1500 && stats[1].waterMl == 1500 && stats[2].waterMl == nil) // logged + other apps
        #expect(stats[6].sleepMin == 480) // in-bed time when "asleep" is missing
        #expect(stats[1].weightKg == nil && stats[1].trendKg == 80) // the trend is carried forward
        #expect(stats[2].bodyFatPct == 20)
        #expect(stats[0].steps == 7000 && stats[2].steps == nil)
        #expect(stats[0].totalBurnedKcal == nil && stats[1].totalBurnedKcal == 2200) // only when both parts are known
    }

    @Test func `weekly report numbers match the charts to the unit`() throws {
        let stats = week()
        let report = WeeklyReport(days: stats)
        func series(_ metric: ChartMetric, unit: EnergyUnit = .kcal) -> ChartSeries {
            ChartBuilder.series(metric, range: .week, stats: stats, unit: unit)
        }
        let intake = try #require(report.averageIntake)
        let energy = try #require(series(.energy).average)
        #expect(energy == intake.kcal)
        #expect(series(.steps).average == report.averageSteps)
        #expect(series(.sleep).average.map { $0 * 60 } == report.averageSleepMin)
        #expect(series(.water).average == report.averageWaterMl)
        // The same rounding on both screens.
        #expect(ChartBuilder.format(energy, .energy, unit: .kcal) == EnergyUnit.kcal.format(intake.kcal))
        let weight = series(.weight)
        #expect(weight.points.last?.reference == report.trendEndKg)
        #expect(weight.points.map(\.reference) == stats.map(\.trendKg))
        // kJ display converts values and targets alike.
        let kilojoules = series(.energy, unit: .kilojoules)
        #expect(try abs(#require(kilojoules.points[0].value) - 1900 * 4.184) < 1e-9)
        #expect(try abs(#require(kilojoules.points[0].reference) - 2400 * 4.184) < 1e-9)
        #expect(kilojoules.unitLabel == "kJ")
        #expect(series(.totalEnergy).daysWithData == 6)

        // Today's half-logged day is drawn but not averaged — in the chart and in the report alike.
        let sunday = stats[6].day
        let open = ChartBuilder.series(.energy, range: .week, stats: stats, unit: .kcal, today: sunday)
        #expect(open.points.last?.value == 1500)
        #expect(open.daysWithData == 5)
        #expect(open.average == WeeklyReport(days: IntakeStats.finished(stats, today: sunday)).averageIntake?.kcal)
        var marked = stats
        marked[6].isComplete = true
        #expect(IntakeStats.finished(marked, today: sunday) == marked)
        #expect(CheckInModel.goalRate(-0.25).hasSuffix("25 kg") && CheckInModel.goalRate(0.5).hasPrefix("+"))
    }

    @Test func `chart series: daily marks, weekly bars for long ranges, summaries`() {
        let start = today.adding(days: -89)
        var stats: [DayStats] = []
        for index in 0 ..< 90 {
            let intake: Nutrients? = index % 10 == 9 ? nil : Nutrients(kcal: 2000, proteinG: 120, carbsG: 220, fatG: 70)
            let trend = 82 - Double(index) * 0.03
            let weight: Double? = index % 3 == 0 ? trend : nil
            stats.append(DayStats(
                day: start.adding(days: index), intake: intake, targetKcal: 2100, steps: 6000 + index * 10, restingHR: 55,
                weightKg: weight, trendKg: trend,
            ))
        }
        let steps = ChartBuilder.series(.steps, range: .quarter, stats: stats, unit: .kcal)
        #expect(steps.bucketDays == 7)
        #expect(steps.points.count == 14) // 90 days starting on a Wednesday touch 14 calendar weeks
        #expect(steps.points.allSatisfy { $0.spanDays == 7 })
        #expect(steps.average == 6445) // the mean of the days, not of the weekly bars
        #expect(steps.daysWithData == 90)

        let heart = ChartBuilder.series(.restingHeartRate, range: .quarter, stats: stats, unit: .kcal)
        #expect(heart.bucketDays == 1 && heart.points.count == 90) // lines stay daily

        let month = Array(stats.suffix(30))
        let energy = ChartBuilder.series(.energy, range: .month, stats: month, unit: .kcal)
        #expect(energy.points.count == 30 && energy.bucketDays == 1)
        #expect(energy.daysWithData == 27)
        #expect(energy.points[0].reference == 2100)
        let macros = ChartBuilder.series(.macros, range: .month, stats: month, unit: .kcal)
        #expect(macros.points.first { $0.proteinG != nil }?.carbsG == 220)

        let weight = ChartBuilder.series(.weight, range: .month, stats: month, unit: .kcal)
        let summary = ChartBuilder.summary(weight, unit: .kcal)
        #expect(summary.hasPrefix("Weight, last 30 days: average "))
        #expect(summary.contains("10 of 30 days have data."))
        #expect(summary.contains("Trend \(Format.kgChange(-0.9)) over the period."))

        let empty = ChartBuilder.series(.hrv, range: .week, stats: Array(stats.suffix(7)), unit: .kcal)
        #expect(empty.isEmpty && empty.average == nil)
        #expect(ChartBuilder.summary(empty, unit: .kcal) == "HRV, last 7 days: no data.")
        #expect(ChartRange.month.days(endingOn: today) == today.adding(days: -29) ... today)
    }

    @Test func `every dashboard tile opens its own chart`() {
        // Caffeine draws its own curve in its detail (no daily-metric chart).
        let charted = DashboardTile.allCases.filter { $0 != .caffeine }
        #expect(Set(charted.compactMap { ChartMetric(tile: $0) }).count == charted.count)
        #expect(ChartMetric(tile: .caffeine) == nil)
        #expect(ChartMetric.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
        #expect(ChartBuilder.format(7.42, .sleep, unit: .kcal) == "\(7.4.formatted(.number.precision(.fractionLength(1)))) h")
    }

    @Test func `a report for any past week, with the estimate that applied`() throws {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        try seedHistory(env)
        try completeProfile(env)
        // A check-in three weeks ago with its own estimate.
        let old = env.today.adding(days: -21)
        let estimate = try #require(CheckInModel(environment: env).estimate)
        try #require(env.checkIns).record(estimate: estimate, checkInDay: old, proposedTargetKcal: 2000, decision: .skipped)

        let lastWeek = env.today.adding(days: -7)
        let report = try WeeklyReportLoader.load(weekStart: lastWeek, environment: env)
        #expect(report.start == lastWeek && report.end == env.today.previous)
        #expect(report.loggedDays == 7)
        #expect(try abs(#require(report.averageIntake).kcal - 2000) < 1e-6)
        #expect(try abs(#require(report.trendChangeKg) - -0.45) < 0.05)
        // The week that just ended uses the live estimate; an older week the check-in made right after it.
        let live = try #require(try Expenditure.snapshot(environment: env)?.kcal)
        #expect(report.expenditureKcal == live)
        #expect(try abs(#require(report.balanceKcal) - -500) < 60)
        let older = try WeeklyReportLoader.load(weekStart: env.today.adding(days: -28), environment: env)
        #expect(older.expenditureKcal == estimate.kcal)
        #expect(older.loggedDays == 7)

        #expect(try WeeklyReportView.title(#require(LocalDay("2026-11-02"))).hasPrefix("2 – "))
        let url = try #require(WeeklyReportView.renderImage(report, unit: .kcal, today: env.today))
        #expect(try Data(contentsOf: url).count > 10000) // a real PNG, rendered on device
    }
}

/// A week that contains today: unfinished totals are drawn but not averaged, the same way in the charts and the report.
@MainActor
struct TrendsTodayTests {
    /// Monday 2 Nov – Sunday 8 Nov 2026 with today on Friday at 8 am: four finished days, a morning's worth of
    /// today and two days still to come.
    private let today = LocalDay("2026-11-06")!

    private func week() -> [DayStats] {
        let monday = LocalDay("2026-11-02")!
        let steps = [9000, 9200, 8800, 9000, 400]
        let water: [Double] = [2000, 2400, 1600, 2000, 300]
        let sleep = [480, 480, 420, 420, 300]
        return (0 ..< 7).map { index in
            let day = monday.adding(days: index)
            guard index < 5 else { return DayStats(day: day, targetKcal: 2000) }
            let isToday = index == 4
            let weight: Double? = index == 0 ? 80 : isToday ? 79 : nil
            return DayStats(
                day: day,
                intake: Nutrients(kcal: isToday ? 450 : 2000, proteinG: isToday ? 20 : 100, carbsG: 200, fatG: 70),
                entryCount: isToday ? 1 : 3, targetKcal: 2000, steps: steps[index], sleepMin: sleep[index],
                activeKcal: isToday ? 100 : 500, basalKcal: isToday ? 700 : 1700, waterMl: water[index],
                weightKg: weight,
            )
        }
    }

    private func series(_ metric: ChartMetric, today: LocalDay?) -> ChartSeries {
        ChartBuilder.series(metric, range: .week, stats: week(), unit: .kcal, today: today)
    }

    @Test func `today's growing totals are drawn but left out of the chart average`() {
        for metric in [ChartMetric.steps, .water, .totalEnergy] {
            let open = series(metric, today: today)
            #expect(open.points.count == 7)
            #expect(open.points[4].value != nil) // today's bar is still there
            #expect(open.daysWithData == 4)
        }
        #expect(series(.steps, today: today).average == 9000)
        #expect(series(.water, today: today).average == 2000)
        #expect(series(.totalEnergy, today: today).average == 2200)
        // Without a today (a past week), every day counts.
        #expect(series(.steps, today: nil).average == 7280)
        #expect(series(.steps, today: nil).daysWithData == 5)
        // Measurements and last night's sleep count today.
        #expect(series(.sleep, today: today).daysWithData == 5 && series(.sleep, today: today).average == 7)
        #expect(series(.weight, today: today).daysWithData == 2 && series(.weight, today: today).average == 79.5)
        // A half-logged day still counts once marked as fully logged; a growing Health total never does.
        var marked = week()
        marked[4].isComplete = true
        let steps = ChartBuilder.series(.steps, range: .week, stats: marked, unit: .kcal, today: today)
        #expect(steps.average == 9000)
    }

    @Test func `the report of the current week matches the charts to the unit`() throws {
        let stats = week()
        // As `WeeklyReportLoader.load` builds it.
        let report = WeeklyReport(days: IntakeStats.finished(stats, today: today), today: today)
        let intake = try #require(report.averageIntake)
        #expect(series(.energy, today: today).average == intake.kcal)
        #expect(intake.kcal == 2000 && report.loggedDays == 4)
        #expect(series(.steps, today: today).average == report.averageSteps)
        #expect(series(.water, today: today).average == report.averageWaterMl)
        #expect(series(.sleep, today: today).average.map { $0 * 60 } == report.averageSleepMin)
        #expect(report.averageSteps == 9000 && report.averageWaterMl == 2000 && report.averageSleepMin == 420)
    }
}

struct BarAxisTopTests {
    private func series(_ points: [ChartPoint], average: Double? = nil) -> ChartSeries {
        ChartSeries(
            metric: .steps, range: .month, points: points, average: average,
            daysWithData: points.count, unitLabel: "steps", bucketDays: 1,
        )
    }

    private func point(_ day: Int, value: Double? = nil) -> ChartPoint {
        ChartPoint(day: LocalDay("2026-11-01")!.adding(days: day), spanDays: 1, value: value)
    }

    @Test func `the axis ends at the next round number above the tallest bar`() {
        let peak = series([point(0, value: 21805), point(1, value: 4517)], average: 9679)
        #expect(ChartBuilder.barAxisTop(peak, goal: 8000) == 25000)
        #expect(ChartBuilder.barAxisTop(series([point(0, value: 12000)]), goal: nil) == 15000)
        #expect(ChartBuilder.barAxisTop(series([point(0, value: 9000)]), goal: nil) == 10000)
        #expect(ChartBuilder.barAxisTop(series([point(0, value: 10000)]), goal: nil) == 10000)
    }

    @Test func `the goal line and stacked bars stay inside the axis`() {
        #expect(ChartBuilder.barAxisTop(series([point(0, value: 6000)]), goal: 10500) == 15000)
        var stacked = point(0)
        stacked.proteinG = 150
        stacked.carbsG = 250
        stacked.fatG = 80
        #expect(ChartBuilder.barAxisTop(series([stacked]), goal: nil) == 500)
        #expect(ChartBuilder.barAxisTop(series([point(0)]), goal: nil) == nil)
    }
}
