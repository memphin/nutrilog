import Foundation
import Testing
@testable import Core

/// Synthetic histories: a body that follows the energy balance exactly, plus optional noise and gaps.
private struct Simulation {
    var tdee: Double
    var startKg: Double = 85
    var days = 60
    var end = LocalDay("2026-11-08")!
    /// Intake actually eaten on day index `i` (0 = oldest).
    var eaten: (Int) -> Double = { _ in 2000 }
    /// Intake written to the diary (differs from `eaten` when under-logging).
    var logged: ((Int) -> Double)?
    /// Days (by index) that were not logged at all.
    var unlogged: Set<Int> = []
    /// Days without a weigh-in.
    var unweighed: Set<Int> = []
    /// Extra scale weight on a day (water).
    var spike: [Int: Double] = [:]

    func history() -> [TDEEDay] {
        let first = end.adding(days: -(days - 1))
        var weight = startKg
        var samples: [LocalDay: Double] = [:]
        var rows: [TDEEDay] = []
        for index in 0 ..< days {
            let day = first.adding(days: index)
            // Morning weigh-in, then the day's balance moves the body.
            let measured = unweighed.contains(index) ? nil : weight + (spike[index] ?? 0)
            if let measured {
                samples[day] = measured
            }
            let isLogged = !unlogged.contains(index)
            rows.append(TDEEDay(
                day: day, kcalIn: isLogged ? (logged ?? eaten)(index) : 0, entryCount: isLogged ? 6 : 0, isComplete: false,
                weightKg: measured,
            ))
            weight += (eaten(index) - tdee) / Energy.kcalPerKg
        }
        let trend = WeightTrend.trendByDay(samples, through: end)
        return rows.map { row in
            var row = row
            row.trendKg = trend[row.day]
            return row
        }
    }
}

struct AdaptiveTDEETests {
    let end = LocalDay("2026-11-08")!

    @Test(arguments: [(2000.0, 2500.0), (2600.0, 2600.0), (3100.0, 2700.0), (1700.0, 2300.0)])
    func `perfect logging recovers the true TDEE within 50 kcal`(intake: Double, tdee: Double) throws {
        let history = Simulation(tdee: tdee, eaten: { _ in intake }).history()
        let estimate = try AdaptiveTDEE.estimate(history: history, endDay: end).get()
        #expect(abs(estimate.kcal - tdee) < 50, "estimated \(estimate.kcal) for \(tdee)")
        #expect(estimate.loggedDays == 14)
        #expect(estimate.windowDays == 14)
        #expect(estimate.trendSpanDays == 14)
        #expect(abs(estimate.meanIntakeKcal - intake) < 0.001)
        #expect(estimate.rawKcal == estimate.kcal) // nothing to blend or clamp
        #expect(!estimate.wasClamped)
    }

    @Test func `varying intake still recovers the TDEE`() throws {
        // Weekdays 1,900, weekends 2,800.
        let history = Simulation(tdee: 2400, eaten: { $0 % 7 < 5 ? 1900 : 2800 }).history()
        let estimate = try AdaptiveTDEE.estimate(history: history, endDay: end).get()
        #expect(abs(estimate.kcal - 2400) < 50)
    }

    @Test func `missing days: logged days are averaged, seven are enough`() throws {
        var simulation = Simulation(tdee: 2500)
        simulation.unlogged = [47, 49, 51, 53, 55, 57, 59] // 7 of the last 14
        // On unlogged days the person still eats the same.
        let estimate = try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get()
        #expect(estimate.loggedDays == 7)
        #expect(abs(estimate.kcal - 2500) < 50)
        #expect(estimate.confidence == .low)

        simulation.unlogged.insert(58)
        #expect(AdaptiveTDEE.estimate(history: simulation.history(), endDay: end) == .failure(.notEnoughLoggedDays(6)))
    }

    @Test func `a day needs three entries or the complete mark to count`() {
        #expect(!TDEEDay(day: end, kcalIn: 900, entryCount: 2, isComplete: false).isLogged)
        #expect(TDEEDay(day: end, kcalIn: 900, entryCount: 3, isComplete: false).isLogged)
        #expect(TDEEDay(day: end, kcalIn: 900, entryCount: 1, isComplete: true).isLogged)
        #expect(TDEEDay(day: end, kcalIn: 0, entryCount: 0, isComplete: true).isLogged) // a fasting day
    }

    @Test func `days missing from the history count as not logged`() {
        let history = Simulation(tdee: 2500).history().filter { $0.day < end.adding(days: -8) }
        #expect(AdaptiveTDEE.estimate(history: history, endDay: end) == .failure(.notEnoughLoggedDays(5)))
    }

    @Test func `a water-weight spike barely moves the estimate`() throws {
        var simulation = Simulation(tdee: 2500)
        simulation.spike = [55: 2.6] // +3 % on one morning inside the window
        let estimate = try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get()
        #expect(abs(estimate.kcal - 2500) < 60)

        // Compared with the same history without the spike the estimate moves by less than 50 kcal; a plain EMA
        // (no outlier handling) would move it by about 90.
        let plainEstimate = try AdaptiveTDEE.estimate(history: Simulation(tdee: 2500).history(), endDay: end).get()
        #expect(abs(estimate.kcal - plainEstimate.kcal) < 50)
    }

    @Test func `missing weigh-ins: the trend is carried forward`() throws {
        var simulation = Simulation(tdee: 2500)
        simulation.unweighed = Set((0 ..< 60).filter { $0 % 2 == 1 }) // every other day
        let estimate = try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get()
        #expect(abs(estimate.kcal - 2500) < 80)
        #expect(estimate.weighIns == 7)
    }

    @Test func `too few weigh-ins or too short a trend give no estimate`() {
        var simulation = Simulation(tdee: 2500)
        simulation.unweighed = Set(0 ..< 59) // one weigh-in, on the last day
        #expect(AdaptiveTDEE.estimate(history: simulation.history(), endDay: end) == .failure(.notEnoughWeighIns(1)))

        simulation.unweighed = Set(0 ..< 55) // weights only on the last five days
        #expect(AdaptiveTDEE.estimate(history: simulation.history(), endDay: end) == .failure(.trendTooShort))
    }

    @Test func `under-logging is flagged and never lowers the target`() throws {
        // Eats 2,600 (maintenance), logs 1,700: the weight stays, so the raw estimate is ~1,700.
        let history = Simulation(tdee: 2600, eaten: { _ in 2600 }, logged: { _ in 1700 }).history()
        let estimate = try AdaptiveTDEE.estimate(history: history, endDay: end, baselineKcal: 2600).get()
        #expect(estimate.underLoggingSuspected)
        #expect(abs(estimate.rawKcal - 1700) < 50)
        // High confidence (60 perfect days) → no clamp, yet the proposal keeps the current target.
        let proposal = AdaptiveTDEE.proposal(for: estimate, goal: .lose, rateKgPerWeek: 0.5, currentTargetKcal: 2050)
        #expect(proposal.kcal == 2050)
        #expect(proposal.note == .keptBecauseUnderLogging)
        #expect(proposal.computedKcal < 2050)

        // Honest logging is not flagged.
        let honest = try AdaptiveTDEE.estimate(history: Simulation(tdee: 2600).history(), endDay: end, baselineKcal: 2600).get()
        #expect(!honest.underLoggingSuspected)
    }

    @Test func `single days far below the estimate look under-logged unless marked complete`() {
        #expect(AdaptiveTDEE.looksUnderLogged(dayKcal: 900, isComplete: false, estimateKcal: 2400))
        #expect(!AdaptiveTDEE.looksUnderLogged(dayKcal: 900, isComplete: true, estimateKcal: 2400))
        #expect(!AdaptiveTDEE.looksUnderLogged(dayKcal: 1300, isComplete: false, estimateKcal: 2400))
        #expect(!AdaptiveTDEE.looksUnderLogged(dayKcal: 900, isComplete: false, estimateKcal: nil))
    }

    @Test func `blends 70 / 30 with the previous estimate`() throws {
        let history = Simulation(tdee: 2500).history()
        let fresh = try AdaptiveTDEE.estimate(history: history, endDay: end).get()
        let blended = try AdaptiveTDEE.estimate(history: history, endDay: end, previousKcal: 2000).get()
        #expect(abs(blended.kcal - (0.7 * fresh.rawKcal + 0.3 * 2000)) < 0.001)
        #expect(blended.previousKcal == 2000)
        #expect(blended.rawKcal == fresh.rawKcal)
    }

    @Test func `clamps to 25 percent of the baseline until confidence is high`() throws {
        // 20 days of history: enough for an estimate, not for high confidence.
        var simulation = Simulation(tdee: 3200, eaten: { _ in 3200 })
        simulation.days = 20
        let estimate = try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end, baselineKcal: 2400).get()
        #expect(estimate.confidence == .medium)
        #expect(estimate.wasClamped)
        #expect(estimate.kcal == 3000) // 2,400 × 1.25
        #expect(abs(estimate.rawKcal - 3200) < 50)

        // The same person with 60 days of history: high confidence, no clamp.
        simulation.days = 60
        let trusted = try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end, baselineKcal: 2400).get()
        #expect(trusted.confidence == .high)
        #expect(!trusted.wasClamped)
        #expect(abs(trusted.kcal - 3200) < 50)

        // Low side.
        var low = Simulation(tdee: 1500, eaten: { _ in 1500 })
        low.days = 20
        let lowEstimate = try AdaptiveTDEE.estimate(history: low.history(), endDay: end, baselineKcal: 2400).get()
        #expect(lowEstimate.kcal == 1800)
        #expect(lowEstimate.wasClamped)
    }

    @Test func `confidence rules`() throws {
        // High: 21+ days of history with at least 80 % of the last 21 logged.
        var simulation = Simulation(tdee: 2500)
        #expect(try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get().confidence == .high)

        simulation.unlogged = [39, 41, 43, 45] // 17 of the last 21 logged = 81 %
        #expect(try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get().confidence == .high)

        simulation.unlogged = [39, 41, 43, 45, 46] // 16 of 21 = 76 %; 13 of the window's 14
        #expect(try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get().confidence == .medium)

        // Medium needs 10 logged days and 4 weigh-ins in the window.
        simulation.unlogged = [46, 48, 50, 52, 54] // 9 logged in the window
        #expect(try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get().confidence == .low)

        simulation.unlogged = []
        simulation.unweighed = Set(46 ..< 60).subtracting([46, 52, 59]) // 3 weigh-ins in the window
        #expect(try AdaptiveTDEE.estimate(history: simulation.history(), endDay: end).get().confidence == .low)

        // Only 18 days of history: never high.
        var short = Simulation(tdee: 2500)
        short.days = 18
        #expect(try AdaptiveTDEE.estimate(history: short.history(), endDay: end).get().confidence == .medium)
        #expect(TDEEConfidence.low < .medium && TDEEConfidence.medium < .high)
    }

    @Test func `proposal is estimate plus the goal delta rounded to 10`() throws {
        let estimate = try AdaptiveTDEE.estimate(history: Simulation(tdee: 2500, eaten: { _ in 2500 }).history(), endDay: end).get()
        let lose = AdaptiveTDEE.proposal(for: estimate, goal: .lose, rateKgPerWeek: 0.5, currentTargetKcal: 2300)
        #expect(lose.note == .fromEstimate)
        #expect(lose.kcal == ((estimate.kcal - 550) / 10).rounded() * 10)
        let maintain = AdaptiveTDEE.proposal(for: estimate, goal: .maintain, rateKgPerWeek: 0.5, currentTargetKcal: nil)
        #expect(maintain.kcal == (estimate.kcal / 10).rounded() * 10)
        let gain = AdaptiveTDEE.proposal(for: estimate, goal: .gain, rateKgPerWeek: 0.25, currentTargetKcal: nil)
        #expect(gain.kcal == ((estimate.kcal + 275) / 10).rounded() * 10)
    }

    @Test func `proposal never goes below the floor`() throws {
        let estimate = try AdaptiveTDEE.estimate(history: Simulation(tdee: 1600, eaten: { _ in 1600 }).history(), endDay: end).get()
        let proposal = AdaptiveTDEE.proposal(for: estimate, goal: .lose, rateKgPerWeek: 1, currentTargetKcal: nil)
        #expect(proposal.kcal == AdaptiveTDEE.minimumTargetKcal)
        #expect(proposal.note == .raisedToFloor)
        #expect(proposal.computedKcal < 1200)
    }

    @Test func `derived numbers explain the estimate`() throws {
        let estimate = try AdaptiveTDEE.estimate(history: Simulation(tdee: 2500).history(), endDay: end).get()
        // 500 kcal/day deficit ≈ −0.45 kg/week.
        #expect(abs(estimate.weeklyChangeKg - -500 * 7 / 7700) < 0.05)
        #expect(abs(estimate.dailyBalanceKcal - -500) < 50)
        #expect(abs(estimate.meanIntakeKcal - estimate.dailyBalanceKcal - estimate.rawKcal) < 0.001)
        #expect(estimate.trendStartDay == end.adding(days: -14))
        for reason in [TDEEUnavailable.notEnoughLoggedDays(3), .notEnoughWeighIns(1), .trendTooShort] {
            #expect(!reason.explanation.isEmpty)
        }
        #expect(TDEEConfidence.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

struct CheckInScheduleTests {
    @Test func `due from the scheduled weekday until a check-in is made`() throws {
        let monday = try #require(LocalDay("2026-11-09"))
        #expect(CheckInSchedule.latestScheduledDay(onOrBefore: monday, weekday: 2) == monday)
        #expect(CheckInSchedule.latestScheduledDay(onOrBefore: monday.adding(days: 3), weekday: 2) == monday)
        #expect(CheckInSchedule.latestScheduledDay(onOrBefore: monday.previous, weekday: 2) == monday.adding(days: -7))
        #expect(CheckInSchedule.latestScheduledDay(onOrBefore: monday, weekday: 1) == monday.previous) // Sunday

        #expect(CheckInSchedule.isDue(today: monday, weekday: 2, lastCheckIn: nil))
        #expect(CheckInSchedule.isDue(today: monday, weekday: 2, lastCheckIn: monday.adding(days: -7)))
        #expect(CheckInSchedule.isDue(today: monday.adding(days: 2), weekday: 2, lastCheckIn: monday.previous))
        #expect(!CheckInSchedule.isDue(today: monday, weekday: 2, lastCheckIn: monday))
        #expect(!CheckInSchedule.isDue(today: monday.adding(days: 6), weekday: 2, lastCheckIn: monday.adding(days: 1)))
        #expect(CheckInSchedule.isDue(today: monday.adding(days: 7), weekday: 2, lastCheckIn: monday.adding(days: 1)))
    }
}
