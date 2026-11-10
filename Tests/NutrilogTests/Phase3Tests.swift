import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Nutrilog

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

@MainActor
struct ExpenditureTests {
    let clock = ManualClock() // Monday 2026-11-09
    let env: AppEnvironment

    init() {
        env = AppEnvironment.preview(clock: clock.appClock)
    }

    @Test func `estimate from the diary and manual weights recovers the true expenditure`() throws {
        try seedHistory(env)
        try completeProfile(env)
        let snapshot = try #require(try Expenditure.snapshot(environment: env))
        let estimate = try snapshot.estimate.get()
        #expect(abs(estimate.kcal - 2500) < 50)
        #expect(estimate.day == env.today.previous) // today is still being logged
        #expect(estimate.loggedDays == 14)
        #expect(estimate.confidence == .high)
        // ~82 kg, 180 cm, 36 y, male, moderate ≈ 2,750 kcal.
        #expect(try abs(#require(snapshot.baselineKcal) - 2750) < 80)
        // Lose 0.5 kg/week → 550 kcal below maintenance, rounded to 10.
        let proposal = try #require(snapshot.proposal)
        #expect(proposal.kcal == ((estimate.kcal - 550) / 10).rounded() * 10)
        #expect(snapshot.goalChangeKgPerWeek == -0.5)
        #expect(snapshot.isCheckInDue)
        #expect(snapshot.kcal == estimate.kcal)
    }

    @Test func `no estimate with too little data, with the reason`() throws {
        let empty = try #require(try Expenditure.snapshot(environment: env))
        #expect(empty.estimate == .failure(.notEnoughLoggedDays(0)))
        #expect(empty.proposal == nil)
        #expect(empty.baselineKcal == nil)

        try seedHistory(env, days: 5)
        #expect(try Expenditure.snapshot(environment: env)?.estimate == .failure(.notEnoughLoggedDays(5)))
    }

    @Test func `days with fewer than three entries count only when marked complete`() throws {
        try seedHistory(env)
        let diary = try #require(env.diary)
        // Remove two of the three entries on ten days of the window.
        for offset in 1 ... 10 {
            let day = env.today.adding(days: -offset)
            let entries = try diary.diary(for: day).sections.flatMap(\.entries)
            try diary.softDelete(entryIDs: entries.dropFirst().map(\.id))
        }
        #expect(try Expenditure.snapshot(environment: env)?.estimate == .failure(.notEnoughLoggedDays(4)))
        for offset in 1 ... 10 {
            try diary.setDayNote(day: env.today.adding(days: -offset), text: "", isComplete: true)
        }
        #expect(try Expenditure.snapshot(environment: env)?.estimate.get().loggedDays == 14)
    }

    @Test func `the weight trend is stored on the Health rows`() throws {
        try seedHistory(env, days: 10)
        let metrics = try #require(env.dailyMetrics)
        try metrics.upsert((1 ... 10).map { DailyHealthMetrics(day: env.today.adding(days: -$0), steps: 5000) })
        env.refreshStoredWeightTrend()
        let rows = try metrics.metrics(in: env.today.adding(days: -10) ... env.today)
        #expect(rows.count == 10)
        #expect(rows.first?.weightTrendKg == 85) // the first weigh-in starts the trend
        let stats = try StatsLoader.load(env.today.adding(days: -10) ... env.today.previous, environment: env)
        #expect(stats.count == rows.count)
        for (day, row) in zip(stats, rows) {
            #expect(try abs(#require(day.trendKg) - #require(row.weightTrendKg)) < 1e-9)
        }
    }
}

@MainActor
struct CheckInModelTests {
    let clock = ManualClock()
    let env: AppEnvironment

    init() throws {
        env = AppEnvironment.preview(clock: clock.appClock)
        try seedHistory(env)
        try completeProfile(env)
        try #require(env.profiles).setTarget(Target(
            effectiveFrom: env.today.adding(days: -30), kcal: 2300, macros: MacroTargets(proteinG: 172.5, carbsG: 230, fatG: 76.7),
            fiberG: 30, origin: .formula,
        ))
    }

    @Test func `accept applies the proposal as an adaptive target from today and records the check-in`() throws {
        let model = CheckInModel(environment: env)
        let proposal = try #require(model.snapshot?.proposal)
        #expect(model.accept())

        let target = try #require(try env.profiles?.target(on: env.today))
        #expect(target.kcal == proposal.kcal)
        #expect(target.origin == .adaptive)
        #expect(target.effectiveFrom == env.today)
        #expect(target.fiberG == 30)
        // The 30 / 40 / 30 split of the old target is kept at the new energy.
        #expect(abs(target.proteinG - proposal.kcal * 0.3 / 4) <= 1)
        #expect(abs(target.fatG - proposal.kcal * 0.3 / 9) <= 1)
        #expect(try env.profiles?.target(on: env.today.previous)?.kcal == 2300)

        let record = try #require(try env.checkIns?.latest())
        #expect(record.decision == .accepted)
        #expect(record.computedForDay == env.today)
        #expect(record.previousTargetKcal == 2300)
        #expect(record.appliedTargetKcal == proposal.kcal)
        #expect(record.estimate?.days.count == 14)
        // The check-in is done for this week.
        #expect(model.snapshot?.isCheckInDue == false)
        #expect(model.snapshot?.currentTarget?.kcal == proposal.kcal)
    }

    @Test func `edited and skipped decisions`() throws {
        let model = CheckInModel(environment: env)
        #expect(!model.applyEdited(kcal: 100))
        #expect(model.errorMessage != nil)
        #expect(try env.checkIns?.history().isEmpty == true)

        #expect(model.skip())
        #expect(try env.checkIns?.latest()?.decision == .skipped)
        #expect(try env.profiles?.target(on: env.today)?.kcal == 2300)

        #expect(model.applyEdited(kcal: 2111.4))
        let record = try #require(try env.checkIns?.latest())
        #expect(record.decision == .edited)
        #expect(record.appliedTargetKcal == 2111)
        #expect(try env.checkIns?.history().count == 1) // same day: replaced
        #expect(try env.profiles?.target(on: env.today)?.origin == .adaptive)
    }

    @Test func `the next estimate is blended with the last check-in's`() throws {
        let model = CheckInModel(environment: env)
        let first = try #require(model.estimate)
        #expect(first.previousKcal == nil)
        #expect(model.accept())
        // A week later.
        clock.advance(hours: 7 * 24)
        env.refreshToday()
        // The window still holds seven logged days from before; the new estimate leans on the last check-in's.
        let later = CheckInModel(environment: env)
        let second = try #require(later.estimate)
        #expect(second.previousKcal == first.kcal)
        #expect(abs(second.kcal - (0.7 * second.rawKcal + 0.3 * first.kcal)) < 1e-6)
        #expect(second.loggedDays == 7)
        #expect(later.snapshot?.isCheckInDue == true)
    }

    @Test func `every number has an explanation, including the proposal's safeguards`() throws {
        let model = CheckInModel(environment: env)
        let facts = model.facts
        #expect(facts.map(\.kind) == [.weeklyChange, .goal, .intake, .estimate, .confidence, .baseline, .currentTarget, .proposal])
        #expect(facts.allSatisfy { !$0.value.isEmpty && $0.explanation.count > 20 })
        let estimate = try #require(model.estimate)
        #expect(facts[3].explanation.contains(env.energyUnit.format(estimate.rawKcal)))
        #expect(facts[0].value.hasPrefix("−")) // losing

        var low = estimate
        low.underLoggingSuspected = true
        let kept = AdaptiveTDEE.proposal(for: low, goal: .lose, rateKgPerWeek: 0.5, currentTargetKcal: 2300)
        #expect(kept.kcal == 2300)
        let text = CheckInModel.proposalExplanation(kept, estimate: low, goalChangeKgPerWeek: -0.5, unit: .kcal)
        #expect(text.contains("does not lower your target"))
        #expect(CheckInModel.estimateExplanation(low, unit: .kcal).contains("wasn't logged"))
    }

    @Test func `the sheet opens by itself only on the check-in weekday, once, when there is something to show`() throws {
        let snapshot = try #require(try Expenditure.snapshot(environment: env))
        #expect(snapshot.today.weekday == 2 && snapshot.profile.checkinWeekday == 2)
        #expect(CheckInPrompt.shouldOpen(snapshot: snapshot, promptedDay: nil))
        #expect(CheckInPrompt.shouldOpen(snapshot: snapshot, promptedDay: "2026-11-02"))
        #expect(!CheckInPrompt.shouldOpen(snapshot: snapshot, promptedDay: "2026-11-09"))

        var tuesday = snapshot
        tuesday.today = snapshot.today.next
        #expect(!CheckInPrompt.shouldOpen(snapshot: tuesday, promptedDay: nil))
        #expect(tuesday.isCheckInDue) // still offered in Trends

        var noEstimate = snapshot
        noEstimate.estimate = .failure(.trendTooShort)
        #expect(!CheckInPrompt.shouldOpen(snapshot: noEstimate, promptedDay: nil))

        #expect(CheckInModel(environment: env).skip())
        let done = try #require(try Expenditure.snapshot(environment: env))
        #expect(!CheckInPrompt.shouldOpen(snapshot: done, promptedDay: nil))
    }

    @Test func `reminder components and history summary`() throws {
        let components = LocalNotificationCheckInReminder.components(weekday: 2, hour: 9)
        #expect(components.weekday == 2 && components.hour == 9 && components.minute == 0)
        #expect(LocalNotificationCheckInReminder.components(weekday: 9, hour: 30).weekday == 7)
        #expect(CheckInSettingsView.weekdays.map(\.number) == [2, 3, 4, 5, 6, 7, 1])

        #expect(CheckInModel(environment: env).accept())
        let record = try #require(try env.checkIns?.latest())
        #expect(CheckInHistoryView.summary(record, unit: .kcal).contains("accepted"))
    }

    @Test func `editing macros in Profile & targets keeps an adaptive target adaptive`() throws {
        #expect(CheckInModel(environment: env).accept())
        let profiles = try #require(env.profiles)
        let adaptive = try #require(try profiles.target(on: env.today))
        let model = TargetsModel(today: env.today)
        try model.load(profile: profiles.profile(), target: adaptive, latestWeightKg: 80)
        #expect(model.overrideKcal) // shown as it is, not replaced by the formula
        #expect(model.effectiveKcal == adaptive.kcal)
        model.fiberG = "35"
        #expect(model.makeTarget()?.origin == .adaptive)
        model.manualKcal = "2222"
        #expect(model.makeTarget()?.origin == .manual)
    }
}

@MainActor
struct DiaryPhase3Tests {
    let clock = ManualClock()
    let env: AppEnvironment

    init() {
        env = AppEnvironment.preview(clock: clock.appClock)
    }

    @Test func `under-logging hints are gentle and only for finished, unmarked days`() {
        let today = env.today
        func hint(day: LocalDay, kcal: Double, entries: Int, complete: Bool = false, estimate: Double? = 2400) -> String? {
            DiaryHints.hint(
                day: day,
                today: today,
                kcal: kcal,
                entryCount: entries,
                isComplete: complete,
                estimateKcal: estimate,
                unit: .kcal,
            )
        }
        #expect(hint(day: today.previous, kcal: 900, entries: 5)?.contains("less than half") == true)
        #expect(hint(day: today.previous, kcal: 900, entries: 5, complete: true) == nil)
        #expect(hint(day: today, kcal: 300, entries: 1) == nil) // today is still being logged
        #expect(hint(day: today.previous, kcal: 0, entries: 0) == nil)
        #expect(hint(day: today.previous, kcal: 2000, entries: 5) == nil)
        #expect(hint(day: today.previous, kcal: 2000, entries: 2)?.contains("fewer than 3") == true)
        #expect(hint(day: today.previous, kcal: 900, entries: 5, estimate: nil) == nil)
    }

    @Test func `a low day warns but never changes the target`() async throws {
        try seedHistory(env)
        try completeProfile(env)
        let profiles = try #require(env.profiles), diary = try #require(env.diary)
        try profiles.setTarget(Target(
            effectiveFrom: env.today.adding(days: -40), kcal: 2300, macros: MacroTargets(proteinG: 150, carbsG: 250, fatG: 78),
            origin: .manual,
        ))
        let yesterday = env.today.previous
        let entries = try diary.diary(for: yesterday).sections.flatMap(\.entries)
        try diary.softDelete(entryIDs: entries.dropFirst().map(\.id)) // one entry of ~667 kcal left

        let model = DiaryModel(environment: env, day: yesterday)
        let observing = Task { await model.observeDiary() }
        defer { observing.cancel() }
        #expect(await waitUntil { model.diary?.entryCount == 1 })
        model.reloadEstimate()
        #expect(model.estimateKcal != nil)
        #expect(model.loggingHint?.contains("less than half") == true)
        #expect(try profiles.targetHistory().map(\.kcal) == [2300])

        model.toggleComplete()
        #expect(await waitUntil { model.diary?.note?.isComplete == true })
        #expect(model.loggingHint == nil)
        #expect(try profiles.targetHistory().map(\.kcal) == [2300])
    }

    @Test func `save as meal, then log it with a changed amount`() throws {
        let foods = try #require(env.foods), diary = try #require(env.diary), meals = try #require(env.meals)
        let oats = try foods.save(FoodDetail(food: Food(name: "Oats", per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 6))))
            .food
        let milk = try foods.save(FoodDetail(
            food: Food(name: "Milk", per100: Nutrients(kcal: 60, proteinG: 3, carbsG: 5, fatG: 3), isLiquid: true),
        )).food
        try diary.log(food: oats, quantity: .base(60), slotID: "breakfast", day: env.today)
        try diary.log(food: milk, quantity: .base(250), slotID: "breakfast", day: env.today)

        let model = DiaryModel(environment: env)
        #expect(model.saveAsMeal(slotID: "breakfast", name: "Porridge"))
        #expect(model.undo.current?.message.contains("Porridge") == true)
        #expect(!model.saveAsMeal(slotID: "dinner", name: "Nothing"))
        #expect(model.errorMessage == "This meal has no foods to save.")

        let meal = try #require(try meals.templates().first)
        var draft = MealLogDraft(meal)
        #expect(draft.lines.map(\.amountText) == ["60", "250"])
        #expect(draft.totals.kcal == 228 + 150)
        draft.lines[1].amountText = "300"
        #expect(draft.totals.kcal == 228 + 180)
        draft.lines[0].amountText = ""
        #expect(draft.logItems == nil) // an included line without an amount blocks logging
        draft.lines[0].isIncluded = false
        let items = try #require(draft.logItems)
        #expect(items.count == 1)
        try meals.log(templateID: meal.id, items: items, slotID: "snacks", day: env.today.next)
        #expect(try diary.totals(for: env.today.next).kcal == 180)
        draft.lines[1].isIncluded = false
        #expect(draft.logItems == nil)

        // Undo removes the saved meal.
        model.undo.current?.undo()
        #expect(try meals.templates().isEmpty)
    }

    @Test func `recipe editor: amounts, scaling and validation`() throws {
        let foods = try #require(env.foods), recipes = try #require(env.recipes)
        let rice = try foods.save(FoodDetail(food: Food(name: "Rice", per100: Nutrients(kcal: 360, proteinG: 7, carbsG: 79, fatG: 1)))).food
        let model = RecipeEditorModel()
        #expect(model.isNew)
        #expect(model.validationErrors.count == 2)
        model.name = "Plain rice"
        model.add(rice)
        #expect(model.rows[0].gramsText == "100")
        model.rows[0].gramsText = "200"
        model.cookedText = "500"
        model.servingsText = "2"
        #expect(model.validationErrors.isEmpty)
        let nutrition = try #require(model.nutrition)
        #expect(nutrition.per100.kcal == 144)
        #expect(nutrition.servingG == 250)

        model.scale(by: 1.5)
        #expect(model.rows[0].grams == 300)
        #expect(Format.number(model.cookedText) == 750)
        #expect(model.nutrition?.per100.kcal == 144) // a bigger batch of the same dish

        model.rows[0].gramsText = "abc"
        #expect(model.validationErrors == ["Every ingredient needs an amount greater than zero."])
        model.rows[0].gramsText = "300"
        model.servingsText = "0"
        #expect(model.validationErrors.count == 1)
        model.servingsText = "3"

        let saved = try model.save(to: recipes)
        #expect(!model.isNew)
        #expect(saved.food.source == .recipe)
        let reopened = try RecipeEditorModel(recipe: #require(recipes.recipe(id: saved.id)))
        #expect(reopened.name == "Plain rice")
        #expect(reopened.rows.map(\.gramsText) == ["300"])
        #expect(reopened.cookedText == "750")
        #expect(reopened.servingsText == "3")
        reopened.remove(atOffsets: [0])
        #expect(reopened.validationErrors == ["Add at least one ingredient."])
    }

    @Test func `the history calendar asks the diary for a day`() {
        let day = env.today.adding(days: -40)
        env.openDiary(on: day)
        #expect(env.selectedTab == .diary)
        #expect(env.diaryDayRequest == day)
    }
}

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
                weights.append(DayWeight(day: row.day, kg: kg, bodyFatPct: 20, isManual: false))
            }
        }
        return StatsBuilder.build(
            range: monday ... monday.adding(days: 6), summaries: summaries, targets: targets, metrics: metrics,
            dayWeights: weights, loggedWaterMl: [monday: 1500, monday.next: 1000],
        )
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
        #expect(summary.contains("Trend \(DashboardFormat.kgChange(-0.9)) over the period."))

        let empty = ChartBuilder.series(.hrv, range: .week, stats: Array(stats.suffix(7)), unit: .kcal)
        #expect(empty.isEmpty && empty.average == nil)
        #expect(ChartBuilder.summary(empty, unit: .kcal) == "HRV, last 7 days: no data.")
        #expect(ChartRange.month.days(endingOn: today) == today.adding(days: -29) ... today)
    }

    @Test func `every dashboard tile opens its own chart`() {
        #expect(Set(DashboardTile.allCases.map { ChartMetric(tile: $0) }).count == DashboardTile.allCases.count)
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

@MainActor
struct IntentActionsTests {
    let clock = ManualClock() // noon → lunch
    let source = FakeHealthDataSource()
    let writer: FakeHealthWriter
    let env: AppEnvironment
    let actions: IntentActions

    init() {
        writer = FakeHealthWriter(mirror: source)
        env = AppEnvironment.preview(clock: clock.appClock, health: source, healthWriter: writer)
        actions = IntentActions(environment: env)
    }

    @Test func `log favorite: usual amount, explicit amount, through the same repositories and Health`() async throws {
        let foods = try #require(env.foods), diary = try #require(env.diary)
        let coffee = try foods.save(FoodDetail(
            food: Food(name: "Coffee with milk", per100: Nutrients(kcal: 40, proteinG: 2, carbsG: 3, fatG: 2), isLiquid: true),
            servings: [Serving(label: "cup", grams: 200)],
        ))
        try foods.setFavorite(id: coffee.food.id, true)
        #expect(try actions.favorites().map(\.name) == ["Coffee with milk"])
        #expect(try actions.currentSlot().id == "lunch")

        // Never logged: 100 ml by default.
        let first = try await actions.logFood(id: coffee.food.id, amount: nil)
        #expect(first.contains("Coffee with milk") && first.contains("Lunch"))
        // An explicit amount, then "the usual" repeats it.
        _ = try await actions.logFood(id: coffee.food.id, amount: 250)
        _ = try await actions.logFood(id: coffee.food.id, amount: nil)
        let entries = try diary.diary(for: env.today).sections.first { $0.slot.id == "lunch" }?.entries ?? []
        #expect(entries.map(\.grams) == [100, 250, 250])
        #expect(try foods.food(id: coffee.food.id)?.useCount == 3)
        // Written to Apple Health before the intent returns.
        #expect(writer.snapshot.samples(for: entries[1].id).contains { $0.type == .dietaryEnergyConsumed && $0.value == 100 })
        #expect(try HealthKitLinkRepository(#require(env.db), clock: clock.appClock).pending().isEmpty)

        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.logFood(id: coffee.food.id, amount: 0) }
        try foods.softDelete(id: coffee.food.id)
        await #expect(throws: IntentActions.Failure.foodNotFound) { try await actions.logFood(id: coffee.food.id, amount: nil) }
        #expect(try actions.foods(ids: [coffee.food.id, "nope"]).isEmpty)
    }

    @Test func `quick-add and remaining calories`() async throws {
        #expect(try actions.remainingSentence().contains("Set a calorie target"))
        try #require(env.profiles).setTarget(Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 67), origin: .manual,
        ))
        #expect(try actions.remaining().remainingKcal == 2000)
        let message = try await actions.quickAdd(kcal: 640, name: "Lunch out")
        #expect(message == "Added 640 kcal to Lunch. You have \(EnergyUnit.kcal.format(1360)) left today.")
        let entry = try #require(try env.diary?.diary(for: env.today).sections.flatMap(\.entries).first)
        #expect(entry.isQuickAdd && entry.displayName == "Lunch out" && entry.mealSlotID == "lunch")
        #expect(!writer.snapshot.samples(for: entry.id).isEmpty)

        _ = try await actions.quickAdd(kcal: 1500, name: nil)
        #expect(try actions.remainingSentence() == "You are 140 kcal over your target today.")
        #expect(try actions.remaining().remainingKcal == -140)
        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.quickAdd(kcal: -5, name: nil) }
    }

    @Test func `log water counts other apps' water and reaches Health`() async throws {
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: env.today, waterMl: 400)])
        let message = try await actions.logWater(ml: 330)
        #expect(message == "Logged 330 ml of water. 730 of 2500 ml today.")
        let entry = try #require(try env.water?.entries(for: env.today).first)
        #expect(writer.snapshot.samples(for: entry.id).first?.type == .dietaryWater)
        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.logWater(ml: 0) }
    }

    @Test func `the evening is dinner, and a new day is picked up`() async throws {
        clock.advance(hours: 7) // 19:00
        #expect(try actions.currentSlot().id == "dinner")
        clock.advance(hours: 24)
        let yesterday = env.today
        _ = try await actions.quickAdd(kcal: 100, name: nil)
        #expect(env.today == yesterday.next)
        #expect(try env.diary?.diary(for: yesterday.next).entryCount == 1)
    }

    @Test func `intents fail clearly without a database`() async {
        let broken = IntentActions(environment: AppEnvironment(
            database: .failed("x"),
            config: AppConfig(usdaAPIKey: nil),
            bundledIndex: nil,
        ))
        await #expect(throws: IntentActions.Failure.databaseUnavailable) { try await broken.logWater(ml: 100) }
        #expect(throws: IntentActions.Failure.databaseUnavailable) { try broken.remaining() }
    }
}

@MainActor
struct WidgetAndBackupTests {
    let clock = ManualClock()

    @Test func `widget snapshot follows the diary, target, water and Health`() throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let suite = "widget-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try #require(env.profiles).setTarget(Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 67), origin: .manual,
        ))
        let lunch = Nutrients(kcal: 640, proteinG: 40, carbsG: 60, fatG: 20)
        try #require(env.diary).logQuickAdd(name: nil, nutrients: lunch, slotID: "lunch", day: env.today)
        try #require(env.water).add(ml: 500, day: env.today)
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: env.today, steps: 8123, sleepAsleepMin: 431, waterMl: 250)])
        try #require(env.weights).add(kg: 81.4)

        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        let snapshot = try #require(WidgetSnapshot.load(defaults: defaults))
        #expect(snapshot.day == "2026-11-09")
        #expect(snapshot.kcal == 640 && snapshot.targetKcal == 2000)
        #expect(snapshot.proteinG == 40 && snapshot.targetCarbsG == 200)
        #expect(snapshot.steps == 8123 && snapshot.sleepMin == 431)
        #expect(snapshot.waterMl == 750 && snapshot.waterGoalMl == 2500)
        #expect(snapshot.weightKg == 81.4)
        #expect(snapshot.energyUnit == "kcal")

        // Unchanged data: the stored snapshot (and its timestamp) stays, so the widgets aren't reloaded for nothing.
        clock.advance(hours: 1)
        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        #expect(WidgetSnapshot.load(defaults: defaults)?.updatedAt == snapshot.updatedAt)
        let snack = Nutrients(kcal: 100, proteinG: 0, carbsG: 0, fatG: 0)
        try #require(env.diary).logQuickAdd(name: nil, nutrients: snack, slotID: "lunch", day: env.today)
        WidgetSnapshotWriter.write(from: env, defaults: defaults)
        #expect(WidgetSnapshot.load(defaults: defaults)?.kcal == 740)
        #expect(WidgetSnapshot.load(defaults: UserDefaults(suiteName: "widget-empty-\(UUID().uuidString)")) == nil)
    }

    @Test func `backups are off without a folder and weekly with one`() async throws {
        #expect(AppEnvironment.preview(clock: clock.appClock).backups == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("app-backups-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = AppEnvironment.preview(clock: clock.appClock, backupsDirectory: dir)
        let backups = try #require(env.backups)
        env.backupIfDue()
        // The backup runs in a detached low-priority task: give a busy CI runner time to get to it.
        #expect(await waitUntil(timeout: .seconds(30)) { (try? backups.list().count) == 1 })
        // A second request the same week writes nothing (checked directly: there is no task to wait for).
        #expect(try backups.backupIfDue() == nil)
        #expect(try backups.list().count == 1)
        #expect(DuplicateFoodsView.facts(FoodDetail(food: Food(name: "X", per100: .zero), barcodes: ["1"])) == "Logged 0 times · 1 barcode")
    }
}
