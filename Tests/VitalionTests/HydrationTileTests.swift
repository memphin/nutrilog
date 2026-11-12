import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// The Hydration tile (spec §3): every drink against the day's goal, the breakdown, the colour from the status and
/// the strip of today's drinks; and `HydrationDayBuilder`, the one construction of a day's `HydrationDay`.
struct HydrationTileTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        return calendar
    }()

    let today = LocalDay("2026-11-11")!

    /// `hour:minute` on `today` (or `days` later).
    func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: today.startDate(calendar: calendar))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func water(_ ml: Double, at date: Date) -> FluidIntake {
        FluidIntake(id: UUID().uuidString, ml: ml, at: date, kind: .water, source: .water, name: "Water")
    }

    func drink(_ ml: Double, at date: Date, source: FluidIntake.Source = .diary, name: String = "Cola") -> FluidIntake {
        FluidIntake(id: UUID().uuidString, ml: ml, at: date, kind: .other, source: source, name: name)
    }

    /// Today's dashboard data: the drinks, other apps' water and the weight trend, stored on `trendDay` (default
    /// today) and carried forward to today as `HydrationGoalResolver.trendsKg(in:environment:)` reads it.
    func data(
        _ intakes: [FluidIntake], otherAppsMl: Double? = nil, trendKg: Double? = nil, trendDay: LocalDay? = nil,
    ) -> DashboardData {
        var data = DashboardData(today: today)
        data.hydrationIntakes = [today: intakes]
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, waterMl: otherAppsMl), fetchedAt: Date())]
        if let trendKg {
            var day = trendDay ?? today
            while day <= today {
                data.weightTrends[day] = trendKg
                day = day.next
            }
        }
        return data
    }

    func day(_ data: DashboardData, now: Date) -> HydrationDay {
        DashboardSnapshot(data, calendar: calendar).hydrationDay(now: now, calendar: calendar)
    }

    // MARK: Tile

    @Test func `tile shows total and breakdown`() {
        let intakes = [
            water(500, at: at(8)), water(500, at: at(10, 30)),
            drink(330, at: at(12, 30)), drink(210, at: at(14), source: .caffeine, name: "Cappuccino"),
        ]
        // 80 kg → 2 400 ml; 300 ml of water from other apps.
        let data = data(intakes, otherAppsMl: 300, trendKg: 80)
        let snapshot = DashboardSnapshot(data, calendar: calendar)
        #expect(snapshot.water.totalMl == 1840)
        #expect(snapshot.water.goalMl == 2400)
        let day = snapshot.hydrationDay(now: at(15), calendar: calendar)
        #expect(day.totalMl == 1840)
        let english = Locale(identifier: "en_US")
        #expect(HydrationTileText.total(day, locale: english) == "1,840 / 2,400 ml")
        // Other apps' water is water.
        #expect(HydrationTileText.breakdown(day, locale: english) == "1,300 water · 540 drinks")
        // Grouped like every other number on Today.
        #expect(HydrationTileText.total(day, locale: Locale(identifier: "hr_HR")) == "1.840 / 2.400 ml")
    }

    @Test func `tile status behind colors orange`() {
        // 300 ml by 14:30, when the pace line is at 1 200: 900 behind, no gap since the drink at 14:00.
        let behind = day(data([water(300, at: at(14))], trendKg: 80), now: at(14, 30))
        #expect(behind.status == .behind(byMl: 900))
        #expect(WaterGoal.band(status: behind.status) == .near)
        #expect(GoalColor.hydration(behind.status) == GoalColor.near)

        // Plain on pace, green at the goal, orange during a long gap too; never red.
        let onPace = day(data([water(1000, at: at(13))], trendKg: 80), now: at(14, 30))
        #expect(onPace.status == .onPace)
        #expect(WaterGoal.band(status: onPace.status) == nil)
        #expect(GoalColor.hydration(onPace.status) == .primary)
        let reached = day(data([water(2400, at: at(9))], trendKg: 80), now: at(14, 30))
        #expect(GoalColor.hydration(reached.status) == GoalColor.reached)
        let gap = day(data([water(500, at: at(8))], trendKg: 80), now: at(12))
        #expect(gap.status == .inGap(since: at(8)))
        #expect(WaterGoal.band(status: gap.status) == .near)
        #expect(GoalColor.hydration(gap.status) == GoalColor.near)

        // VoiceOver says what the colour says.
        let snapshot = DashboardSnapshot(data([water(300, at: at(14))], trendKg: 80), calendar: calendar)
        #expect(snapshot.accessibilityLabel(of: .water, state: .ready, now: at(14, 30), calendar: calendar, locale: .dashboardEnglish)
            == "Hydration, 300 of 2,400 millilitres, 900 millilitres behind pace")
    }

    @Test func `goal uses trend weight`() {
        // The latest trend on or before the day: 81.7 kg three days ago → 2 451 → 2 450 ml.
        let trend = data([], trendKg: 81.7, trendDay: today.adding(days: -3))
        #expect(DashboardSnapshot(trend, calendar: calendar).water.goalMl == 2450)
        #expect(day(trend, now: at(12)).goalMl == 2450)
        // No weight yet: the fallback.
        #expect(DashboardSnapshot(data([]), calendar: calendar).water.goalMl == HydrationGoal.fallbackMl)
        // A fixed goal ignores the weight.
        var fixed = trend
        fixed.waterGoalMode = .fixed
        fixed.waterGoalMl = 3000
        #expect(DashboardSnapshot(fixed, calendar: calendar).water.goalMl == 3000)

        // Each day of the sparkline is coloured against its own goal: 70 kg (2 100 ml) until yesterday, 80 kg today.
        var history = data([], trendKg: 70, trendDay: today.adding(days: -5))
        history.weightTrends[today] = 80
        #expect(history.hydrationGoalMl(on: today.adding(days: -5)) == 2100)
        #expect(history.hydrationGoalMl(on: today.adding(days: -4)) == 2100)
        #expect(history.hydrationGoalMl(on: today) == 2400)
        let snapshot = DashboardSnapshot(history, calendar: calendar)
        #expect(snapshot.goalColor(of: .water, value: 2100, day: today.adding(days: -5)) == GoalColor.reached)
        #expect(snapshot.goalColor(of: .water, value: 2100, day: today) == GoalColor.near)
    }

    @Test func `other apps water in total not strip`() {
        let day = day(data([water(250, at: at(9))], otherAppsMl: 300), now: at(10))
        #expect(day.totalMl == 550)
        #expect(day.otherAppsMl == 300)
        #expect(HydrationTileText.breakdown(day) == "550 water · 0 drinks")
        // Untimed, so not on the strip.
        let strip = HydrationStripLayout(day: day)
        #expect(strip.bubbles.count == 1)
        #expect(strip.bubbles.first?.radius == HydrationStripLayout.radius(ml: 250))
        #expect(HydrationStrip.accessibilityLabel(day) == "1 drink")
    }

    @Test func `sparkline counts every drink of the 7 days`() {
        var data = data([water(500, at: at(8)), drink(250, at: at(12))], otherAppsMl: 300)
        data.hydrationIntakes[today.adding(days: -2)] = [drink(330, at: at(12, days: -2))]
        let sparkline = DashboardSnapshot(data, calendar: calendar).sparklines[.water]
        #expect(sparkline?.points.map(\.index) == [4, 6])
        #expect(sparkline?.points.map(\.value) == [330, 1050])
    }

    // MARK: Strip

    @Test func `strip places drinks on the waking window`() {
        // Wake 07:00 (fallback), bedtime 23:00: 16 hours wide.
        let intakes = [water(250, at: at(6)), water(500, at: at(15)), drink(330, at: at(17))]
        let day = day(data(intakes), now: at(19))
        let strip = HydrationStripLayout(day: day)
        // The 06:00 glass is before wake: in the total, not on the strip.
        #expect(strip.bubbles.map(\.x) == [0.5, 0.625])
        #expect(strip.bubbles.map(\.kind) == [.water, .other])
        // Bubble area follows the amount: 500 ml is about 11 pt.
        #expect(abs(HydrationStripLayout.radius(ml: 500) - 11) < 0.001)
        #expect(HydrationStripLayout.radius(ml: 2000) == HydrationStripLayout.maxRadius)
        #expect(HydrationStripLayout.radius(ml: 1) == HydrationStripLayout.minRadius)
        // The gap from wake to the 15:00 glass (8 h).
        #expect(strip.gaps == [HydrationStripLayout.Span(start: 0, end: 0.5)])
        #expect(strip.now == 0.75)
    }

    @Test func `strip has no marks without a window`() {
        let collapsed = HydrationDay(
            intakes: [water(250, at: at(9))], otherAppsMl: 0, goalMl: 2400, wake: at(23), bedtime: at(23),
            gapThreshold: 3 * 3600, behindMarginMl: 500, now: at(23, 30),
        )
        let strip = HydrationStripLayout(day: collapsed)
        #expect(strip.bubbles.isEmpty && strip.gaps.isEmpty && strip.now == nil)
    }

    @Test func `strip is spoken as drinks and the longest gap`() {
        let times = [at(7, 15), at(7, 45), at(8, 15), at(12, 45), at(13, 30), at(14), at(14, 30), at(15)]
        let day = day(data(times.map { water(200, at: $0) }), now: at(15, 30))
        #expect(HydrationStrip.accessibilityLabel(day) == "8 drinks, longest gap 4 h 30 min")
        #expect(HydrationStrip.accessibilityLabel(self.day(data([]), now: at(8))) == "No drinks yet")
        #expect(HydrationStrip.accessibilityLabel(self.day(data([]), now: at(11))) == "No drinks yet, longest gap 4 h")
        #expect(HydrationStrip.gapDuration(45 * 60) == "45 min")
    }

    // MARK: Builder

    @Test func `builder wakes from Health, else at the fallback time`() {
        let settings = HydrationSettings()
        func build(wokeAt: Date?) -> HydrationDay {
            HydrationDayBuilder.make(
                day: today, intakes: [], otherAppsMl: 0, wokeAt: wokeAt, settings: settings, goalMl: 2400, now: at(12),
                calendar: calendar,
            )
        }
        #expect(build(wokeAt: at(6, 12)).wake == at(6, 12))
        #expect(build(wokeAt: nil).wake == at(7))
        #expect(build(wokeAt: at(6, 30, days: -1)).wake == at(7)) // yesterday's: not today's sleep
        #expect(build(wokeAt: nil).bedtime == at(23))
    }

    @Test func `builder passes gap in seconds, margin, other apps water, goal and now`() {
        var settings = HydrationSettings()
        settings.gapMinutes = 120
        settings.behindMarginMl = 750
        let day = HydrationDayBuilder.make(
            day: today, intakes: [water(250, at: at(9))], otherAppsMl: 420, wokeAt: nil, settings: settings,
            goalMl: 2000, now: at(12), calendar: calendar,
        )
        #expect(day.gapThreshold == 7200)
        #expect(day.behindMarginMl == 750)
        #expect(day.otherAppsMl == 420)
        #expect(day.totalMl == 670)
        #expect(day.goalMl == 2000)
        #expect(day.now == at(12))
        // 09:00 → 12:00 is 3 h: a gap with a 2 h threshold.
        #expect(day.status == .inGap(since: at(9)))
    }
}

// MARK: - Model

@MainActor
struct HydrationTileModelTests {
    @Test func `day rollover switches to new day`() async {
        let clock = ManualClock() // noon
        clock.advance(hours: 11 + 59.0 / 60) // 23:59
        let env = AppEnvironment.preview(clock: clock.appClock)
        let firstDay = env.today
        let model = DashboardModel(environment: env)
        var task = Task { await model.observe() }
        model.addWater(ml: 500)
        #expect(await waitUntil { model.hydrationDay(at: model.now).totalMl == 500 })

        clock.advance(hours: 2.0 / 60) // 00:01
        #expect(env.refreshToday())
        // The view restarts the observation when `environment.today` changes (`.task(id:)`).
        task.cancel()
        task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await waitUntil { model.data.today == firstDay.next })
        let day = model.hydrationDay(at: model.now)
        #expect(day.totalMl == 0)
        #expect(day.intakes.isEmpty)
        #expect(LocalDay(day.wake) == firstDay.next)
        #expect(model.snapshot.water.totalMl == 0)
        // Yesterday's glass is still yesterday's.
        #expect(await waitUntil { model.data.hydrationIntakes[firstDay]?.map(\.ml) == [500] })
    }

    @Test func `settings and the goal reach the tile`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let profiles = try #require(env.profiles)
        var settings = HydrationSettings()
        settings.gapMinutes = 90
        try settings.save(to: profiles)
        var profile = try profiles.profile()
        profile.waterGoalMode = .fixed
        profile.waterGoalMl = 3000
        try profiles.save(profile)

        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await waitUntil { model.snapshot.water.goalMl == 3000 })
        #expect(model.hydrationDay(at: model.now).gapThreshold == 90 * 60)
    }

    @Test func `a weight trend from before the history window still sets the goal, as in Settings`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let metrics = try #require(env.dailyMetrics)
        // The last weight is 90 days old, well before the dashboard's 60-day window.
        let old = env.today.adding(days: -90)
        #expect(!DashboardData(today: env.today).window.contains(old))
        _ = try metrics.upsert([DailyHealthMetrics(day: old, weightKg: 80)])
        _ = try metrics.setWeightTrends([old: 80])

        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await waitUntil { model.snapshot.water.goalMl == 2400 })
        #expect(model.hydrationDay(at: model.now).goalMl == 2400)

        // Settings → Hydration reads the weight and the goal the same way.
        let today = env.today
        let settingsTrendKg = HydrationGoalResolver.trendsKg(in: today ... today, environment: env)[today]
        #expect(settingsTrendKg == 80)
        let profile = try #require(env.profiles).profile()
        #expect(
            HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: settingsTrendKg, training: .none)
                == model.snapshot.water.goalMl,
        )
    }

    @Test func `a weight logged in Vitalion without Apple Health sets the goal, on the tile and in Settings`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let today = env.today
        #expect(try #require(env.dailyMetrics).metrics(on: today) == nil) // no Health row, so no stored trend

        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await waitUntil { model.snapshot.water.goalMl == HydrationGoal.fallbackMl })

        // Logged while Today is open: the tile follows.
        try #require(env.weights).add(kg: 80, measuredAt: today.startDate().addingTimeInterval(7 * 3600))
        #expect(await waitUntil { model.snapshot.water.goalMl == 2400 })
        #expect(model.hydrationDay(at: model.now).goalMl == 2400)

        // Settings → Hydration, the widget and Siri read the same weight and goal.
        let settingsTrendKg = HydrationGoalResolver.trendsKg(in: today ... today, environment: env)[today]
        #expect(settingsTrendKg == 80)
        let profile = try #require(env.profiles).profile()
        #expect(HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: settingsTrendKg, training: .none) == 2400)
        #expect(try WaterProgress.read(on: today, environment: env)?.goalMl == 2400)
        // Nothing was written to daily_metrics.
        #expect(try #require(env.dailyMetrics).metrics(on: today) == nil)
    }

    @Test func `weights logged in Vitalion after Apple Health stopped syncing set the goal, not the stale stored trend`() throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let today = env.today
        let metrics = try #require(env.dailyMetrics)
        // Apple Health synced a 90 kg weight (and its stored trend) a month ago, then stopped syncing.
        let lastSync = today.adding(days: -30)
        _ = try metrics.upsert([DailyHealthMetrics(day: lastSync, weightKg: 90)])
        _ = try metrics.setWeightTrends([lastSync: 90])
        // Since then, 80 kg every day logged in Vitalion.
        let weights = try #require(env.weights)
        var day = lastSync.next
        while day <= today {
            try weights.add(kg: 80, measuredAt: day.startDate().addingTimeInterval(7 * 3600))
            day = day.next
        }

        let trends = HydrationGoalResolver.trendsKg(in: today.adding(days: -1) ... today, environment: env)
        let trendKg = try #require(trends[today])
        // The trend computed from every weight, as the weight screens show it — close to 80, not the stale 90.
        let expected = try WeightTrend.trendByDay(
            WeightTrend.samples(StatsLoader.dayWeights(through: today, environment: env)), through: today,
        )[today]
        #expect(trendKg == expected)
        #expect(trendKg < 81) // the stale trend would be 90 (a 2,700 ml goal)
        let profile = try #require(env.profiles).profile()
        #expect(HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: trendKg, training: .none) < 2430)
        #expect(try (WaterProgress.read(on: today, environment: env)?.goalMl ?? 0) < 2430)
    }
}
