import Foundation
import Testing
@testable import Core

struct TrainingDaysTests {
    // 2026-11-09 is a Monday (weekday 2).
    let monday = LocalDay("2026-11-09")!

    func schedule(_ from: String, _ weekdays: Set<Int>, boost: Int = 10) -> TrainingSchedule {
        TrainingSchedule(effectiveFrom: LocalDay(from)!, weekdays: weekdays, boostPercent: boost)
    }

    @Test func `no schedule means no training days and the default boost`() {
        let days = TrainingDays(schedules: [], overrides: [:])
        #expect(!days.isTraining(monday))
        #expect(days.boostPercent(on: monday) == TrainingSchedule.defaultBoostPercent)
        #expect(TrainingSchedule.defaultBoostPercent == 10)
        #expect(days.boost(on: monday) == nil)
        #expect(days.schedule(on: monday) == nil)
    }

    @Test func `weekdays of the schedule are training days`() {
        // Monday, Wednesday, Friday.
        let days = TrainingDays(schedules: [schedule("2026-01-01", [2, 4, 6])], overrides: [:])
        #expect(days.isTraining(monday))
        #expect(!days.isTraining(monday.next)) // Tuesday
        #expect(days.isTraining(monday.adding(days: 2))) // Wednesday
        #expect(days.isTraining(monday.adding(days: 4))) // Friday
        #expect(!days.isTraining(monday.adding(days: 5))) // Saturday
        #expect(!days.isTraining(monday.adding(days: -1))) // Sunday
        #expect(days.scheduledTraining(monday))
        #expect(days.override(on: monday) == nil)
    }

    @Test func `days before the first schedule are not training days`() {
        let days = TrainingDays(schedules: [schedule("2026-11-09", [1, 2, 3, 4, 5, 6, 7], boost: 20)], overrides: [:])
        #expect(!days.isTraining(monday.previous))
        #expect(days.boostPercent(on: monday.previous) == 10)
        #expect(days.isTraining(monday))
        #expect(days.boostPercent(on: monday) == 20)
    }

    @Test func `an override beats the weekday default both ways`() {
        let tuesday = monday.next
        let days = TrainingDays(
            schedules: [schedule("2026-01-01", [2])],
            overrides: [monday: false, tuesday: true],
        )
        #expect(!days.isTraining(monday))
        #expect(days.scheduledTraining(monday))
        #expect(days.override(on: monday) == false)
        #expect(days.isTraining(tuesday))
        #expect(!days.scheduledTraining(tuesday))
        #expect(days.override(on: tuesday) == true)
        #expect(days.boost(on: monday) == nil)
        #expect(days.boost(on: tuesday) == 10)
    }

    @Test func `a training workout makes its day a training day`() {
        let tuesday = monday.next
        let days = TrainingDays(schedules: [schedule("2026-01-01", [2], boost: 15)], overrides: [:], workoutDays: [tuesday])
        #expect(days.isTraining(tuesday))
        #expect(!days.scheduledTraining(tuesday))
        #expect(days.defaultTraining(tuesday))
        #expect(days.boost(on: tuesday) == 15)
        // A workout is not a plan; the schedule is.
        #expect(!days.isPlanned(tuesday))
        #expect(days.isPlanned(monday))
        #expect(!days.isTraining(tuesday.next))
        // Without a schedule the default boost applies.
        #expect(TrainingDays(schedules: [], overrides: [:], workoutDays: [tuesday]).boost(on: tuesday) == 10)
        #expect(TrainingDays(schedules: [], overrides: [:], workoutDays: [tuesday]) != .none)
    }

    @Test func `the user's switch beats a workout`() {
        let tuesday = monday.next
        let days = TrainingDays(schedules: [], overrides: [tuesday: false, monday: true], workoutDays: [tuesday])
        #expect(!days.isTraining(tuesday))
        #expect(days.defaultTraining(tuesday))
        #expect(days.boost(on: tuesday) == nil)
        #expect(!days.isPlanned(tuesday))
        // A day switched on by hand is planned.
        #expect(days.isPlanned(monday))
        #expect(!days.defaultTraining(monday))
    }

    @Test func `an override works without any schedule`() {
        let days = TrainingDays(schedules: [], overrides: [monday: true])
        #expect(days.isTraining(monday))
        #expect(days.boost(on: monday) == TrainingSchedule.defaultBoostPercent)
    }

    @Test func `a schedule change only affects days from its first day`() {
        let days = TrainingDays(
            schedules: [schedule("2026-01-01", [2], boost: 10), schedule("2026-11-10", [3], boost: 15)],
            overrides: [:],
        )
        // Monday 2026-11-02 still uses the old schedule.
        #expect(days.isTraining(LocalDay("2026-11-02")!))
        #expect(days.boost(on: LocalDay("2026-11-02")!) == 10)
        #expect(days.isTraining(monday))
        #expect(!days.isTraining(monday.next.next.next.next.next.next.next)) // next Monday
        #expect(days.isTraining(monday.adding(days: 8))) // Tuesday after the change
        #expect(days.boost(on: monday.adding(days: 8)) == 15)
        #expect(days.schedule(on: monday)?.boostPercent == 10)
    }

    @Test func `an overridden day uses the boost of the schedule in effect that day`() {
        let saturdayBefore = LocalDay("2026-11-07")!
        let saturdayAfter = LocalDay("2026-11-14")!
        let days = TrainingDays(
            schedules: [schedule("2026-01-01", [], boost: 10), schedule("2026-11-10", [], boost: 25)],
            overrides: [saturdayBefore: true, saturdayAfter: true],
        )
        #expect(days.boost(on: saturdayBefore) == 10)
        #expect(days.boost(on: saturdayAfter) == 25)
    }

    @Test func `weekdays outside one to seven are ignored`() {
        let schedule = TrainingSchedule(effectiveFrom: monday, weekdays: [0, 2, 8], boostPercent: 10)
        #expect(schedule.weekdays == [2])
    }

    @Test func `resolvers with the same schedules and overrides are equal`() {
        let a = TrainingDays(schedules: [schedule("2026-01-01", [2])], overrides: [monday: false])
        let b = TrainingDays(schedules: [schedule("2026-01-01", [2])], overrides: [monday: false])
        let c = TrainingDays(schedules: [schedule("2026-01-01", [3])], overrides: [monday: false])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: Boost math

    @Test func `boost raises calories and adds the extra energy as carbs`() {
        let boosted = TrainingBoost.apply(kcal: 2000, carbsG: 200, percent: 10)
        #expect(boosted.kcal == 2200)
        #expect(boosted.carbsG == 250)
    }

    @Test func `boosted calories are rounded to 10 kcal and carbs follow the rounded value`() {
        // 2345 × 1.1 = 2579.5 → 2580; extra 235 kcal → 58.75 g carbs.
        let boosted = TrainingBoost.apply(kcal: 2345, carbsG: 100, percent: 10)
        #expect(boosted.kcal == 2580)
        #expect(boosted.carbsG == 158.75)
        // 1999 × 1.15 = 2298.85 → 2300.
        #expect(TrainingBoost.kcal(1999, percent: 15) == 2300)
    }

    @Test func `a zero boost changes nothing`() {
        let boosted = TrainingBoost.apply(kcal: 2345, carbsG: 123.4, percent: 0)
        #expect(boosted.kcal == 2345)
        #expect(boosted.carbsG == 123.4)
        #expect(TrainingBoost.waterMl(2420, percent: 0) == 2420)
    }

    @Test func `the boost never lowers calories or carbs`() {
        // 4 × 1.1 = 4.4 would round down to 0.
        let boosted = TrainingBoost.apply(kcal: 4, carbsG: 1, percent: 10)
        #expect(boosted.kcal >= 4)
        #expect(boosted.carbsG >= 1)
    }

    @Test func `hydration goal is boosted and rounded to 50 ml`() {
        #expect(TrainingBoost.waterMl(2500, percent: 10) == 2750)
        // 2400 × 1.1 = 2640 → 2650.
        #expect(TrainingBoost.waterMl(2400, percent: 10) == 2650)
        // 2100 × 1.15 = 2415 → 2400.
        #expect(TrainingBoost.waterMl(2100, percent: 15) == 2400)
    }
}
