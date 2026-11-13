import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// Training days: a day's calorie target and hydration goal are boosted wherever the day is judged (Today, the
/// streak, the diary, Trends, the calendar, the widget, Siri), the base target stays for the check-in, and the
/// day's switch keeps an override only while it differs from the schedule.
@MainActor
struct TrainingDayTests {
    let today = LocalDay("2026-11-11")!
    let macros = MacroTargets(proteinG: 150, carbsG: 200, fatG: 70)

    let base = Target(
        effectiveFrom: LocalDay("2026-10-12")!, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 70),
        origin: .manual,
    )

    /// `days` switched on, no schedule: the default 10 % boost.
    func training(_ days: LocalDay...) -> TrainingDays {
        TrainingDays(schedules: [], overrides: Dictionary(uniqueKeysWithValues: days.map { ($0, true) }))
    }

    func intake(_ ml: Double, _ offset: Int) -> FluidIntake {
        let at = today.adding(days: -offset).startDate(calendar: .current).addingTimeInterval(12 * 3600)
        return FluidIntake(id: UUID().uuidString, ml: ml, at: at, kind: .water, source: .water, name: "Water")
    }

    /// An app on `ManualClock`'s day with a 2,000 kcal target and a fixed 2,500 ml hydration goal.
    func environment() throws -> AppEnvironment {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let profiles = try #require(env.profiles)
        try profiles.setTarget(Target(effectiveFrom: env.today.adding(days: -30), kcal: 2000, macros: macros, origin: .manual))
        var profile = try profiles.profile()
        profile.waterGoalMode = .fixed
        profile.waterGoalMl = 2500
        try profiles.save(profile)
        return env
    }

    // MARK: Goals

    @Test func `the hydration goal is boosted on a training day only`() throws {
        let schedule = TrainingSchedule(effectiveFrom: today.adding(days: -7), weekdays: [today.weekday], boostPercent: 10)
        let training = TrainingDays(schedules: [schedule], overrides: [:])
        // 2,400 ml at 80 kg, +10 % rounded to 50 ml.
        #expect(HydrationGoalResolver.goalMl(on: today, mode: .weight, fixedMl: 3000, trendKg: 80, training: training) == 2650)
        #expect(HydrationGoalResolver.goalMl(on: today.next, mode: .weight, fixedMl: 3000, trendKg: 80, training: training) == 2400)
        #expect(HydrationGoalResolver.goalMl(on: today, mode: .fixed, fixedMl: 2500, trendKg: nil, training: training) == 2750)
        #expect(HydrationGoalResolver.goalMl(on: today, mode: .fixed, fixedMl: 2500, trendKg: nil, training: .none) == 2500)
        // The hydration chart colours each day by its own goal.
        var profile = try #require(AppEnvironment.preview().profiles).profile()
        profile.waterGoalMode = .fixed
        profile.waterGoalMl = 2500
        let goals = ChartBuilder.hydrationGoals(in: today.previous ... today, profile: profile, trendsKg: [:], training: training)
        #expect(goals == [today.previous: 2500, today: 2750])
    }

    @Test func `today's energy target and hydration goal are boosted on a training day`() {
        var data = DashboardData(today: today)
        data.target = base
        data.waterGoalMode = .fixed
        data.waterGoalMl = 2500
        #expect(DashboardSnapshot(data).target == base)
        #expect(DashboardSnapshot(data).water.goalMl == 2500)

        data.trainingDays = training(today, today.adding(days: -2))
        let snapshot = DashboardSnapshot(data)
        #expect(snapshot.target?.kcal == 2200)
        #expect(snapshot.target?.carbsG == 250)
        #expect(snapshot.target?.proteinG == 150)
        #expect(snapshot.water.goalMl == 2750)
        // Each sparkline day by its own status.
        #expect(snapshot.hydrationGoals[today.adding(days: -2)] == 2750)
        #expect(snapshot.hydrationGoals[today.previous] == 2500)
    }

    @Test func `the water streak and history judge a past training day against its boosted goal`() {
        var data = DashboardData(today: today)
        data.waterGoalMode = .fixed
        data.waterGoalMl = 2000
        data.hydrationIntakes = Dictionary(uniqueKeysWithValues: [1, 2, 3].map { (today.adding(days: -$0), [intake(2000, $0)]) })
        #expect(DashboardSnapshot(data).streak(for: .water) == Streak(days: 3, includesToday: false, isAtLimit: false))

        // Two days ago was a training day: 2,000 ml falls short of its 2,200 ml.
        data.trainingDays = training(today.adding(days: -2))
        #expect(DashboardSnapshot(data).streak(for: .water) == Streak(days: 1, includesToday: false, isAtLimit: false))
        let rows = TileHistory.rows(for: .water, data: data, loggedFluidByDay: [today.adding(days: -2): 2000, today.previous: 2000])
        #expect(rows[2].goalMl == 2200)
        #expect(rows[1].goalMl == 2000)
    }

    @Test func `trends and the history calendar judge a training day against its boosted target`() throws {
        let timeline = EffectiveTimeline([(from: base.effectiveFrom, value: base)])
        let trainingDay = today.adding(days: -2)
        let summaries = [DiaryDaySummary(
            day: trainingDay, totals: Nutrients(kcal: 2200, proteinG: 150, carbsG: 250, fatG: 70), entryCount: 3, isComplete: true,
        )]
        let stats = StatsBuilder.build(
            range: trainingDay ... today.previous, summaries: summaries, targets: timeline, training: training(trainingDay),
            metrics: [], dayWeights: [], loggedFluidMl: [:],
        )
        #expect(stats.map(\.targetKcal) == [2200, 2000])

        let months = HistoryCalendar.build(
            today: today, summaries: summaries, targets: timeline, training: training(trainingDay), firstWeekday: 2,
        )
        let cell = try #require(months.last?.days.first { $0.day == trainingDay })
        #expect(cell.isTraining)
        #expect(cell.adherence == .onTarget)
        #expect(months.last?.days.filter(\.isTraining).count == 1)
        // Without the training day, 2,200 kcal is 10 % over the target.
        let plain = HistoryCalendar.build(today: today, summaries: summaries, targets: timeline, firstWeekday: 2)
        #expect(plain.last?.days.first { $0.day == trainingDay }?.adherence == .near)
        // The calendar asks for the training days of every day it shows.
        let endOfMonth = try #require(LocalDay("2026-11-30"))
        #expect(HistoryCalendar.days(today: today) == HistoryCalendar.firstDay(today: today) ... endOfMonth)
    }

    @Test func `the widget, Siri and the water read use the boosted goals; the check-in keeps the base target`() throws {
        let env = try environment()
        try #require(env.trainingDays).toggleTraining(on: env.today) // no schedule: a training day

        let widget = try #require(WidgetSnapshotWriter.make(from: env))
        #expect(widget.targetKcal == 2200)
        #expect(widget.targetCarbsG == 250)
        #expect(widget.targetProteinG == 150)
        #expect(widget.waterGoalMl == 2750)
        #expect(try WaterProgress.read(on: env.today, environment: env)?.goalMl == 2750)
        #expect(try IntentActions(environment: env, locale: Locale(identifier: "en_US")).remaining().targetKcal == 2200)
        // The weekly check-in proposes a new base target, so it compares with the base one.
        #expect(try Expenditure.snapshot(environment: env)?.currentTarget?.kcal == 2000)
    }

    // MARK: Live

    @Test func `the Today tab follows the schedule and the day's switch live`() async throws {
        let env = try environment()
        let repo = try #require(env.trainingDays)
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        #expect(await waitUntil { model.snapshot.target?.kcal == 2000 && model.snapshot.water.goalMl == 2500 })
        #expect(model.trainingBoost == nil)

        try repo.setSchedule(weekdays: [env.today.weekday], boostPercent: 20, effectiveFrom: env.today)
        #expect(await waitUntil { model.trainingBoost == 20 })
        #expect(model.snapshot.target?.kcal == 2400)
        #expect(model.snapshot.water.goalMl == 3000)

        try repo.toggleTraining(on: env.today)
        #expect(await waitUntil { model.trainingBoost == nil })
        #expect(model.snapshot.target?.kcal == 2000)
        #expect(model.snapshot.water.goalMl == 2500)
    }

    @Test func `the diary's switch boosts the day's target and keeps an override only when needed`() async throws {
        let env = try environment()
        let repo = try #require(env.trainingDays)
        let day = env.today
        let model = DiaryModel(environment: env)
        let tasks = [Task { await model.observeTarget() }, Task { await model.observeTraining() }]
        defer { tasks.forEach { $0.cancel() } }
        #expect(await waitUntil { model.target?.kcal == 2000 })
        #expect(!model.isTrainingDay)
        #expect(model.trainingBoostPercent == TrainingSchedule.defaultBoostPercent)

        model.toggleTrainingDay()
        #expect(await waitUntil { model.isTrainingDay && model.target?.kcal == 2200 })
        #expect(model.baseTarget?.kcal == 2000)
        #expect(try repo.trainingDays(in: day ... day).overrides == [day: true])

        // Scheduled from today on: switching it off is an override, back on follows the schedule again.
        try repo.setSchedule(weekdays: [day.weekday], boostPercent: 20, effectiveFrom: day)
        #expect(await waitUntil { model.target?.kcal == 2400 && model.trainingBoostPercent == 20 })
        model.toggleTrainingDay()
        #expect(await waitUntil { !model.isTrainingDay && model.target?.kcal == 2000 })
        #expect(try repo.trainingDays(in: day ... day).overrides == [day: false])
        model.toggleTrainingDay()
        #expect(await waitUntil { model.isTrainingDay })
        #expect(try repo.trainingDays(in: day ... day).overrides == [:])
        #expect(model.errorMessage == nil)
    }

    // MARK: Settings and texts

    @Test func `settings list the weekdays from the calendar's first weekday`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2
        let monday = TrainingDaysSettingsView.weekdays(calendar: calendar)
        #expect(monday.map(\.number) == [2, 3, 4, 5, 6, 7, 1])
        #expect(monday.first?.name == "Monday")
        #expect(monday.last?.name == "Sunday")
        calendar.firstWeekday = 1
        #expect(TrainingDaysSettingsView.weekdays(calendar: calendar).map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        calendar.locale = Locale(identifier: "hr_HR")
        calendar.firstWeekday = 2
        #expect(TrainingDaysSettingsView.weekdays(calendar: calendar).first?.name.lowercased() == "ponedjeljak")
        #expect(TrainingDaysSettingsView.boostRange.contains(TrainingSchedule.defaultBoostPercent))
        #expect(TrainingSchedule.boostPercentRange.contains(TrainingDaysSettingsView.boostRange.upperBound))
    }

    @Test func `the boost is a signed percent in the user's locale`() {
        #expect(TrainingDayFormat.boost(10, locale: Locale(identifier: "en_US")) == "+10%")
        #expect(TrainingDayFormat.boost(10, locale: Locale(identifier: "hr_HR")) == "+10\u{00A0}%")
        #expect(TrainingDayFormat.pill(15, locale: Locale(identifier: "en_US")) == "Training day · +15%")
        #expect(TrainingDayFormat.spokenPill(15, locale: Locale(identifier: "en_US")) == "Training day, goals raised by 15%")
        #expect(TrainingDayFormat.symbol(isTraining: true) == "dumbbell.fill")
        #expect(TrainingDayFormat.symbol(isTraining: false) == "dumbbell")
    }
}
