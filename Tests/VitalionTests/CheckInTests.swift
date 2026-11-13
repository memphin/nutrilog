import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

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

    @Test func `the baseline is the 30-day average of Health energy when there is enough`() throws {
        try completeProfile(env)
        let metrics = try #require(env.dailyMetrics)
        // 10 days of 2,200 + 400; today's partial value is left out.
        try metrics.upsert((1 ... 10).map { DailyHealthMetrics(day: env.today.adding(days: -$0), activeKcal: 400, basalKcal: 2200) }
            + [DailyHealthMetrics(day: env.today, activeKcal: 50, basalKcal: 300)])
        let measured = try #require(try Expenditure.measured(environment: env))
        #expect(measured.kcal == 2600 && measured.days == 10)
        try seedHistory(env)
        let snapshot = try #require(try Expenditure.snapshot(environment: env))
        #expect(snapshot.baselineKcal == 2600)
        #expect(snapshot.baselineIsMeasured)
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

    @Test func `a breakfast-only day with three entries is left out of the mean intake`() throws {
        try seedHistory(env)
        let diary = try #require(env.diary)
        let day = env.today.adding(days: -3)
        try diary.softDelete(entryIDs: diary.diary(for: day).sections.flatMap(\.entries).map(\.id))
        for (name, kcal) in [("Coffee", 20.0), ("Milk", 80.0), ("Toast", 250.0)] {
            try diary.logQuickAdd(
                name: name, nutrients: Nutrients(kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0), slotID: "breakfast", day: day,
            )
        }
        let estimate = try #require(try Expenditure.snapshot(environment: env)?.estimate.get())
        #expect(estimate.partialDays == [day])
        #expect(estimate.loggedDays == 13)
        #expect(abs(estimate.meanIntakeKcal - 2000) < 1e-6)
        #expect(abs(estimate.kcal - 2500) < 50)
        #expect(CheckInModel.estimateExplanation(estimate, unit: .kcal).contains("1 partly logged day was left out"))

        // Marked as fully logged, the same day counts.
        try diary.setDayNote(day: day, text: "", isComplete: true)
        let marked = try #require(try Expenditure.snapshot(environment: env)?.estimate.get())
        #expect(marked.partialDaysLeftOut == 0 && marked.loggedDays == 14)
    }

    @Test func `the explanation says how the weight change was measured`() throws {
        try seedHistory(env)
        let estimate = try #require(try Expenditure.snapshot(environment: env)?.estimate.get())
        #expect(estimate.weightMethod == .trend) // 45 days of daily weigh-ins: a mature trend
        #expect(CheckInModel.estimateExplanation(estimate, unit: .kcal).contains(TDEEWeightMethod.trend.explanation))
        #expect(CheckInModel.trendExplanation(estimate).hasPrefix("Your weight trend went"))

        var young = estimate
        young.weightMethod = .weighInLine
        #expect(CheckInModel.estimateExplanation(young, unit: .kcal).contains(TDEEWeightMethod.weighInLine.explanation))
        #expect(CheckInModel.trendExplanation(young).hasPrefix("A straight line through your weigh-ins"))

        // The Trends card names the method too.
        #expect(MaintenanceCard.summary(estimate).contains("logged · trend "))
        #expect(MaintenanceCard.summary(young).contains("logged · weigh-ins "))
        #expect(!MaintenanceCard.summary(young).contains("trend"))
        #expect(MaintenanceCard.summary(young).hasSuffix(" / week"))
        var stored = estimate
        stored.weightMethod = nil // stored before the method was recorded
        #expect(MaintenanceCard.summary(stored).contains("logged · trend "))
    }

    @Test func `a new user's first estimate uses the weigh-ins, not the lagging trend`() throws {
        try seedHistory(env, days: 10)
        let estimate = try #require(try Expenditure.snapshot(environment: env)?.estimate.get())
        #expect(estimate.weightMethod == .weighInLine)
        #expect(estimate.confidence != .high)
        #expect(abs(estimate.rawKcal - 2500) < 1)
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

    @Test func `keeping the calories leaves the macros untouched`() throws {
        let model = CheckInModel(environment: env)
        #expect(model.applyEdited(kcal: 2300)) // the current target's energy
        let target = try #require(try env.profiles?.target(on: env.today))
        #expect(target.kcal == 2300)
        #expect(target.macros == MacroTargets(proteinG: 172.5, carbsG: 230, fatG: 76.7))
        #expect(target.fiberG == 30)

        // Gram targets far from their own energy share are not rewritten either.
        let proteinOnly = Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 0, fatG: 0), origin: .manual,
        )
        #expect(CheckInModel.macros(forKcal: 2000, current: proteinOnly) == proteinOnly.macros)
        let mixed = Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 180, carbsG: 180, fatG: 60), origin: .manual,
        )
        #expect(CheckInModel.macros(forKcal: 2000, current: mixed) == mixed.macros)
    }

    @Test func `a changed calorie target scales the macros proportionally`() throws {
        let current = Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 180, carbsG: 180, fatG: 60), origin: .manual,
        )
        #expect(CheckInModel.macros(forKcal: 2200, current: current) == MacroTargets(proteinG: 198, carbsG: 198, fatG: 66))
        let proteinOnly = Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 0, fatG: 0), origin: .manual,
        )
        #expect(CheckInModel.macros(forKcal: 1800, current: proteinOnly) == MacroTargets(proteinG: 135, carbsG: 0, fatG: 0))
        // Without a current target: 30 / 40 / 30.
        #expect(CheckInModel.macros(forKcal: 2000, current: nil) == MacroSplit.balanced.grams(forKcal: 2000))

        let model = CheckInModel(environment: env)
        #expect(model.applyEdited(kcal: 2070)) // 0.9 × 2300
        let target = try #require(try env.profiles?.target(on: env.today))
        #expect(target.macros == MacroTargets(proteinG: 155, carbsG: 207, fatG: 69))
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
