import Foundation
import Testing
@testable import Core

struct HydrationTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    let goalMl = 2400.0
    let gapThreshold: TimeInterval = 3 * 3600
    let marginMl = 500.0

    /// 2026-11-11 at `hour:minute` UTC.
    func t(_ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute))!
    }

    var wake: Date {
        t(7)
    }

    var bedtime: Date {
        t(23)
    }

    var tomorrowWake: Date {
        wake.addingTimeInterval(24 * 3600)
    }

    func water(_ ml: Double, at date: Date) -> FluidIntake {
        FluidIntake(id: UUID().uuidString, ml: ml, at: date, kind: .water, source: .water, name: "Water")
    }

    func day(
        _ intakes: [FluidIntake] = [],
        otherAppsMl: Double = 0,
        wake: Date? = nil,
        marginMl: Double? = nil,
        now: Date,
    ) -> HydrationDay {
        HydrationDay(
            intakes: intakes,
            otherAppsMl: otherAppsMl,
            goalMl: goalMl,
            wake: wake ?? self.wake,
            bedtime: bedtime,
            gapThreshold: gapThreshold,
            behindMarginMl: marginMl ?? self.marginMl,
            now: now,
        )
    }

    // MARK: - Totals and steps

    @Test func `totals split by kind`() {
        let intakes = [
            water(250, at: t(8)),
            water(500, at: t(10)),
            FluidIntake(id: "d1", ml: 330, at: t(12), kind: .other, source: .diary, name: "Orange juice"),
            FluidIntake(id: "c1", ml: 240, at: t(9), kind: .other, source: .caffeine, name: "Filter coffee"),
        ]
        let day = day(intakes, otherAppsMl: 200, now: t(13))
        #expect(day.totalMl == 1520)
        #expect(day.waterMl == 750)
        #expect(day.otherDrinksMl == 570)
        #expect(day.otherAppsMl == 200)
        // Steps: timed intakes only (no other-apps water), cumulative, in time order.
        #expect(day.steps.map(\.at) == [t(8), t(9), t(10), t(12)])
        #expect(day.steps.map(\.totalMl) == [250, 490, 990, 1320])
        #expect(day.lastIntakeAt == t(12))
    }

    @Test func `intakes in time order`() {
        let coffee = FluidIntake(id: "c1", ml: 240, at: t(9), kind: .other, source: .caffeine, name: "Filter coffee")
        let glass = FluidIntake(id: "w1", ml: 500, at: t(15), kind: .water, source: .water, name: "Water")
        let early = FluidIntake(id: "w2", ml: 250, at: t(6), kind: .water, source: .water, name: "Water")
        // Every intake, also one before wake (for the strip and the detail's list), sorted by time.
        #expect(day([glass, coffee, early], now: t(16)).intakes == [early, coffee, glass])
    }

    // MARK: - Pace

    @Test func `pace is linear to bedtime minus one hour`() {
        let day = day(now: t(12))
        #expect(day.paceEnd == t(22))
        #expect(day.isWindowValid)
        #expect(day.pace(at: t(7)) == 0)
        #expect(day.pace(at: t(14, 30)) == 1200)
        #expect(day.pace(at: t(22)) == 2400)
        #expect(day.pace(at: t(22, 45)) == 2400)
        #expect(day.pace(at: t(6)) == 0)
    }

    // MARK: - Gaps

    @Test func `gaps between drinks and ongoing`() {
        let drinks = [t(7, 30), t(8, 15), t(10), t(12, 30), t(13)].map { water(200, at: $0) }
        let afternoon = day(drinks, now: t(17))
        #expect(afternoon.gaps == [HydrationGap(start: t(13), end: t(17), isOngoing: true)])

        let evening = day(drinks + [water(200, at: t(17, 30))], now: t(18))
        #expect(evening.gaps == [HydrationGap(start: t(13), end: t(17, 30), isOngoing: false)])
    }

    @Test func `gap from wake when no drinks`() {
        #expect(day(now: t(10, 30)).gaps == [HydrationGap(start: t(7), end: t(10, 30), isOngoing: true)])
        #expect(day(now: t(9, 59)).gaps.isEmpty)
    }

    @Test func `gap exactly at threshold is not a gap`() {
        let day = day([water(250, at: t(8)), water(250, at: t(11))], now: t(12))
        #expect(day.gaps.isEmpty)
    }

    @Test func `night and out-of-window drinks don't make gaps`() {
        let day = day([water(300, at: t(2))], now: t(12))
        #expect(day.totalMl == 300)
        #expect(day.gaps == [HydrationGap(start: t(7), end: t(12), isOngoing: true)])
    }

    // MARK: - Status

    @Test func `status precedence`() {
        // Goal reached wins even during a gap.
        let reached = day([water(2400, at: t(8))], now: t(15))
        #expect(reached.gaps.last?.isOngoing == true)
        #expect(reached.status == .goalReached)

        // Ongoing gap.
        let inGap = day([water(1000, at: t(8))], now: t(12))
        #expect(inGap.status == .inGap(since: t(8)))

        // 600 below pace (1200 at 14:30), no gap.
        let behind = day([water(300, at: t(9)), water(300, at: t(12))], now: t(14, 30))
        #expect(behind.gaps.isEmpty)
        #expect(behind.status == .behind(byMl: 600))

        // 300 below pace: within the margin.
        let onPace = day([water(300, at: t(9)), water(600, at: t(12))], now: t(14, 30))
        #expect(onPace.status == .onPace)
    }

    @Test func `invalid window`() {
        let day = day(wake: t(22, 30), now: t(23))
        #expect(day.isWindowValid == false)
        #expect(day.pace(at: t(22, 45)) == nil)
        #expect(day.gaps.isEmpty)
        #expect(day.status == .onPace)
        let tomorrowWake = t(22, 30).addingTimeInterval(24 * 3600)
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: tomorrowWake.addingTimeInterval(gapThreshold), reason: .gap(since: tomorrowWake)),
        )
    }

    // MARK: - Reminder

    @Test func `reminder gap wins`() {
        let day = day([water(1000, at: t(9)), water(1000, at: t(13))], now: t(14))
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: t(16), reason: .gap(since: t(13))),
        )
    }

    @Test func `reminder behind wins`() {
        let day = day([water(100, at: t(9))], now: t(9, 30))
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: t(10, 45), reason: .behind(expectedMl: 600)),
        )
    }

    @Test func `reminder behind clamped uses pace at now`() {
        // 300 ml in sips, last at 17:30: behind time 07:00 + 800/2400 · 15 h = 12:00 has passed, gap time is 20:30.
        let sips = [t(9), t(12), t(15), t(17, 30)].map { water(75, at: $0) }
        let day = day(sips, now: t(17, 30))
        #expect(day.pace(at: t(17, 30)) == 1680)
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: t(17, 30), reason: .behind(expectedMl: 1680)),
        )
    }

    @Test func `no reminder when goal reached`() {
        let day = day([water(2400, at: t(9))], now: t(10))
        #expect(HydrationReminder.next(day: day, tomorrowWake: tomorrowWake) == nil)
    }

    @Test func `reminder after pace end rolls to tomorrow`() {
        let day = day([water(1000, at: t(12)), water(1000, at: t(20, 30))], now: t(21))
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: tomorrowWake.addingTimeInterval(gapThreshold), reason: .gap(since: tomorrowWake)),
        )
    }

    @Test func `reminder never in the past`() {
        // Behind time 07:00 + 1000/2400 · 15 h = 13:15; gap time 10:00 has passed, so it fires now.
        let day = day(marginMl: 1000, now: t(10, 20))
        #expect(
            HydrationReminder.next(day: day, tomorrowWake: tomorrowWake)
                == HydrationReminder.Plan(date: t(10, 20), reason: .gap(since: t(7))),
        )
    }

    // MARK: - Fluid rule and goal

    @Test func `fluid rule`() {
        #expect(FluidRule.counts(isLiquid: true, fatPer100: 0, override: nil) == true)
        #expect(FluidRule.counts(isLiquid: true, fatPer100: 91, override: nil) == false)
        #expect(FluidRule.counts(isLiquid: false, fatPer100: 0, override: nil) == false)
        #expect(FluidRule.counts(isLiquid: false, fatPer100: 0, override: true) == true)
        #expect(FluidRule.counts(isLiquid: true, fatPer100: 0, override: false) == false)
    }

    @Test func `goal from weight`() {
        #expect(HydrationGoal.ml(weightKg: 80, mode: .weight, fixedMl: 1800) == 2400)
        #expect(HydrationGoal.ml(weightKg: 73, mode: .weight, fixedMl: 1800) == 2200) // 2190 rounds to 2200
        #expect(HydrationGoal.ml(weightKg: nil, mode: .weight, fixedMl: 1800) == 2500)
        #expect(HydrationGoal.ml(weightKg: 80, mode: .fixed, fixedMl: 1800) == 1800)
    }
}
