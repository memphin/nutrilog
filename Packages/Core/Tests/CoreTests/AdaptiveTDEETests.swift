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

/// Day-by-day histories for the young-trend, sparse and after-gap scenarios: a body that follows the energy balance
/// exactly (weighed before the day's balance), perfect logging, the trend from `WeightTrend.trendByDay` as in the app.
private struct Scenario {
    var tdee: Double
    var intake: Double
    var startKg: Double
    var first = LocalDay("2026-08-01")!
    var days = 60
    var weighed: (Int) -> Bool = { _ in true }
    /// Scale noise added to the weigh-in of day `i`.
    var noise: (Int) -> Double = { _ in 0 }
    /// A weigh-in long before `first`, with logged days from it on (at `intake`) but no other weigh-ins.
    var oldWeighIn: (day: LocalDay, kg: Double)?

    func history() -> [TDEEDay] {
        var rows: [TDEEDay] = []
        var samples: [LocalDay: Double] = [:]
        if let old = oldWeighIn {
            samples[old.day] = old.kg
            var day = old.day
            while day < first {
                rows.append(TDEEDay(day: day, kcalIn: intake, entryCount: 5, isComplete: false, weightKg: samples[day]))
                day = day.next
            }
        }
        var weight = startKg
        for index in 0 ..< days {
            let day = first.adding(days: index)
            let measured = weighed(index) ? weight + noise(index) : nil
            samples[day] = measured
            rows.append(TDEEDay(day: day, kcalIn: intake, entryCount: 5, isComplete: false, weightKg: measured))
            weight += (intake - tdee) / Energy.kcalPerKg
        }
        let trend = WeightTrend.trendByDay(samples, through: first.adding(days: days - 1))
        return rows.map { row in
            var row = row
            row.trendKg = trend[row.day]
            return row
        }
    }

    /// The estimate on each day `n` (1-based: the window ends on day `n` of the scenario) that has one, as the app would
    /// compute it then: only history up to that day, the baseline at the true value so the clamp never helps.
    func estimates() -> [(dayNumber: Int, estimate: TDEEEstimate)] {
        let history = history()
        return (1 ... days).compactMap { number in
            let end = first.adding(days: number - 1)
            let known = history.filter { $0.day <= end }
            return (try? AdaptiveTDEE.estimate(history: known, endDay: end, baselineKcal: tdee).get()).map { (number, $0) }
        }
    }
}

/// The estimator before the young-trend fix: the trend difference over the window, whatever the trend's age.
private func trendDifferenceRaw(_ history: [TDEEDay], end: LocalDay) -> Double? {
    let byDay = Dictionary(history.map { ($0.day, $0) }) { first, _ in first }
    let start = end.adding(days: -(AdaptiveTDEE.windowDays - 1))
    let window = (0 ..< AdaptiveTDEE.windowDays).compactMap { byDay[start.adding(days: $0)] }
    let logged = window.filter(\.isLogged)
    guard let first = ([byDay[start.previous]].compactMap(\.self) + window).first(where: { $0.trendKg != nil }),
          let trendStart = first.trendKg, let trendEnd = byDay[end]?.trendKg, !logged.isEmpty
    else { return nil }
    let mean = logged.reduce(0) { $0 + $1.kcalIn } / Double(logged.count)
    return mean - (trendEnd - trendStart) * Energy.kcalPerKg / Double(first.day.days(until: end))
}

/// SplitMix64, so the noisy scenario is the same on every run.
private struct SeededRandom {
    var state: UInt64

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// The estimate while the weight trend is young, sparse or restarting after a gap (backlog #34 review). Before the
/// fix: a new user with a 550 kcal deficit got 2,181 / 2,266 / 2,405 after 8 / 14 / 21 days (true 2,550); weekly
/// weigh-ins 2,300 after 60 days; after a 60-day gap 3,996 at 14 days (true 2,300).
struct AdaptiveTDEEYoungTrendTests {
    @Test func `new user with daily weigh-ins: right from the first estimate, high confidence only once the trend is mature`() throws {
        let estimates = Scenario(tdee: 2550, intake: 2000, startKg: 90).estimates()
        #expect(estimates.first?.dayNumber == 8)
        for (number, estimate) in estimates {
            #expect(abs(estimate.rawKcal - 2550) <= 120, "day \(number): \(estimate.rawKcal)")
            #expect(abs(estimate.kcal - 2550) <= 120, "day \(number): \(estimate.kcal)")
            // The trend reaches back 28 days from day 29 on.
            let mature = number >= AdaptiveTDEE.matureTrendDays + 1
            #expect(estimate.resolvedWeightMethod == (mature ? .trend : .weighInLine), "day \(number)")
            if !mature {
                #expect(estimate.confidence != .high, "day \(number)")
            }
        }
        let byNumber = Dictionary(uniqueKeysWithValues: estimates.map { ($0.dayNumber, $0.estimate) })
        // Day 21 used to read "High confidence" with the clamp lifted at 2,405.
        let day21 = try #require(byNumber[21])
        #expect(day21.confidence == .medium)
        #expect(abs(day21.kcal - 2550) < 1)
        // The line's ends describe what was used: 15 weigh-ins from the day before the window, slope × span.
        #expect(day21.trendSpanDays == 14)
        #expect(abs(day21.dailyBalanceKcal - -550) < 1)
        #expect(abs(day21.meanIntakeKcal - day21.dailyBalanceKcal - day21.rawKcal) < 1e-6)
        #expect(try #require(byNumber[45]).confidence == .high)
        // Day 8: the window has 8 weigh-ins, the line starts on the first.
        let day8 = try #require(byNumber[8])
        #expect(day8.trendStartDay == LocalDay("2026-08-01"))
        #expect(day8.trendSpanDays == 7)
        #expect(abs(day8.trendStartKg - 90) < 1e-9)
    }

    @Test(arguments: [7, 3])
    func `sparse weigh-ins: right on every estimate, never high confidence`(every interval: Int) {
        var scenario = Scenario(tdee: 2550, intake: 2000, startKg: 90)
        scenario.weighed = { $0.isMultiple(of: interval) }
        let estimates = scenario.estimates()
        #expect(estimates.count > 40)
        for (number, estimate) in estimates {
            #expect(abs(estimate.rawKcal - 2550) <= 120, "every \(interval) days, day \(number): \(estimate.rawKcal)")
            #expect(estimate.resolvedWeightMethod == .weighInLine)
            #expect(estimate.confidence != .high)
        }
    }

    @Test func `after a long gap: the old weigh-in does not read as weight change`() {
        // 90 kg once, 65 days before 40 days of daily weigh-ins at a stable 86 kg, eating at maintenance throughout.
        var scenario = Scenario(tdee: 2300, intake: 2300, startKg: 86)
        scenario.days = 40
        scenario.oldWeighIn = (scenario.first.adding(days: -65), 90)
        let estimates = scenario.estimates()
        #expect(estimates.first?.dayNumber == 8)
        for (number, estimate) in estimates {
            #expect(estimate.rawKcal - 2300 <= 300, "day \(number): \(estimate.rawKcal)")
            if number >= 14 {
                #expect(abs(estimate.rawKcal - 2300) <= 150, "day \(number): \(estimate.rawKcal)")
            }
            // The trend restarted with the daily weigh-ins: no high confidence until it is four weeks old again.
            if number <= AdaptiveTDEE.matureTrendDays {
                #expect(estimate.confidence != .high, "day \(number)")
                #expect(estimate.resolvedWeightMethod == .weighInLine)
            }
        }
    }

    @Test func `the restart rule and the maturity rule`() throws {
        let day = LocalDay("2026-08-01")!
        #expect(AdaptiveTDEE.trendStart(weighInDays: []) == nil)
        #expect(AdaptiveTDEE.trendStart(weighInDays: [day]) == day)
        // A 13-day gap keeps the history, a 14-day gap restarts it.
        #expect(AdaptiveTDEE.trendStart(weighInDays: [day, day.adding(days: 13), day.adding(days: 14)]) == day)
        #expect(AdaptiveTDEE.trendStart(weighInDays: [day, day.adding(days: 14), day.adding(days: 15)]) == day.adding(days: 14))

        // Mature but every other day: 7 weigh-ins in the window are enough for the trend.
        var simulation = Scenario(tdee: 2500, intake: 2000, startKg: 85)
        simulation.weighed = { $0.isMultiple(of: 2) }
        let history = simulation.history()
        let end = simulation.first.adding(days: 59)
        let estimate = try AdaptiveTDEE.estimate(history: history, endDay: end).get()
        #expect(estimate.weighIns == 7)
        #expect(estimate.resolvedWeightMethod == .trend)
        #expect(estimate.confidence == .high)
        // The same with one weigh-in fewer in the window: the line, and no high confidence.
        let thinned = history.map { row in
            var row = row
            if row.day == end.adding(days: -1) {
                row.weightKg = nil
            }
            return row
        }
        let sparse = try AdaptiveTDEE.estimate(history: thinned, endDay: end).get()
        #expect(sparse.weighIns == 6)
        #expect(sparse.resolvedWeightMethod == .weighInLine)
        #expect(sparse.confidence == .medium)
        #expect(abs(sparse.rawKcal - 2500) < 1)
    }

    @Test func `the line leaves out weigh-ins the trend marks as outliers`() throws {
        // 20 days of daily weigh-ins (young trend), one morning +3 % inside the window.
        var scenario = Scenario(tdee: 2500, intake: 2000, startKg: 85)
        scenario.days = 20
        scenario.noise = { $0 == 15 ? 2.6 : 0 }
        let end = scenario.first.adding(days: 19)
        let estimate = try AdaptiveTDEE.estimate(history: scenario.history(), endDay: end).get()
        #expect(estimate.resolvedWeightMethod == .weighInLine)
        #expect(abs(estimate.rawKcal - 2500) < 1)
    }

    /// Daily scale noise of ±0.4 kg (uniform; water, food in the gut), 30 days, 200 seeds. On day 30 the trend is
    /// mature, so the estimate is exactly the trend difference — the approach before the fix — and its error is the
    /// trend's own noise (≈ 65 kcal RMSE; asserted < 90 to leave room for the seed set, not for a method change).
    /// While the trend is young the line is noisier than a mature trend but has no warm-up bias: on day 14 its RMSE is
    /// far below the old trend difference's (≈ 125 vs ≈ 300).
    @Test func `noisy weigh-ins: the same as before for mature data, better while young`() throws {
        var squaredNew: [Int: Double] = [:], squaredOld: [Int: Double] = [:]
        let checkDays = [14, 30]
        for seed in 1 ... 200 {
            var random = SeededRandom(state: UInt64(seed))
            let noise = (0 ..< 30).map { _ in (random.unit() * 2 - 1) * 0.4 }
            var scenario = Scenario(tdee: 2550, intake: 2000, startKg: 90)
            scenario.days = 30
            scenario.noise = { noise[$0] }
            let history = scenario.history()
            for number in checkDays {
                let end = scenario.first.adding(days: number - 1)
                let known = history.filter { $0.day <= end }
                let estimate = try AdaptiveTDEE.estimate(history: known, endDay: end).get()
                let old = try #require(trendDifferenceRaw(known, end: end))
                if number == 30 {
                    #expect(estimate.resolvedWeightMethod == .trend)
                    #expect(abs(estimate.rawKcal - old) < 1e-9)
                }
                squaredNew[number, default: 0] += pow(estimate.rawKcal - 2550, 2)
                squaredOld[number, default: 0] += pow(old - 2550, 2)
            }
        }
        let rmse = { (sum: Double?) in sqrt((sum ?? 0) / 200) }
        #expect(rmse(squaredNew[30]) < 90, "day 30 RMSE \(rmse(squaredNew[30]))")
        #expect(rmse(squaredNew[14]) < 160, "day 14 RMSE \(rmse(squaredNew[14]))")
        #expect(rmse(squaredNew[14]) < rmse(squaredOld[14]) * 0.6, "day 14: \(rmse(squaredNew[14])) vs \(rmse(squaredOld[14]))")
    }
}

/// Partly logged days (backlog #34 review): a day with three entries but only breakfast must not drag the mean down.
struct AdaptiveTDEEPartialDayTests {
    let end = LocalDay("2026-11-08")!

    /// 60 days eating 2,200 against a TDEE of 2,500; in the window only the days in `loggedOffsets` (0 = `end`) are
    /// logged at 2,200, plus `extra` days with their own row.
    private func history(loggedOffsets: [Int], extra: [Int: (kcal: Double, entries: Int, complete: Bool)] = [:]) -> [TDEEDay] {
        var simulation = Simulation(tdee: 2500, eaten: { _ in 2200 })
        let windowIndexes = Set(46 ..< 60)
        simulation.unlogged = windowIndexes.subtracting(loggedOffsets.map { 59 - $0 })
        return simulation.history().map { row in
            var row = row
            if let day = extra[row.day.days(until: end)] {
                row.kcalIn = day.kcal
                row.entryCount = day.entries
                row.isComplete = day.complete
            }
            return row
        }
    }

    @Test func `a breakfast-only day with three entries no longer moves the estimate`() throws {
        let logged = [0, 2, 4, 6, 8, 10, 12]
        let base = try AdaptiveTDEE.estimate(history: history(loggedOffsets: logged), endDay: end).get()
        #expect(base.loggedDays == 7 && base.partialDaysLeftOut == 0)
        #expect(abs(base.meanIntakeKcal - 2200) < 1e-9)

        // Coffee, milk and toast (~350 kcal) on one more day.
        let breakfast = try AdaptiveTDEE.estimate(
            history: history(loggedOffsets: logged, extra: [5: (350, 3, false)]), endDay: end,
        ).get()
        #expect(breakfast.loggedDays == 7)
        #expect(breakfast.partialDays == [end.adding(days: -5)])
        #expect(breakfast.partialDaysLeftOut == 1)
        #expect(breakfast.meanIntakeKcal == base.meanIntakeKcal)
        #expect(breakfast.rawKcal == base.rawKcal)
        #expect(breakfast.kcal == base.kcal)
        #expect(breakfast.isPartial(end.adding(days: -5)))
        #expect(!breakfast.isUsed(try #require(breakfast.days.first { $0.day == end.adding(days: -5) })))
        #expect(breakfast.isUsed(try #require(breakfast.days.first { $0.day == end })))
    }

    @Test func `the seven-day minimum counts only the days that remain`() {
        let result = AdaptiveTDEE.estimate(
            history: history(loggedOffsets: [0, 2, 4, 6, 8, 10], extra: [5: (350, 3, false)]), endDay: end,
        )
        #expect(result == .failure(.notEnoughLoggedDays(6)))
    }

    @Test func `a genuinely low day marked complete still counts`() throws {
        let logged = [0, 2, 4, 6, 8, 10, 12]
        let estimate = try AdaptiveTDEE.estimate(
            history: history(loggedOffsets: logged, extra: [5: (350, 3, true)]), endDay: end,
        ).get()
        #expect(estimate.loggedDays == 8)
        #expect(estimate.partialDaysLeftOut == 0)
        #expect(estimate.partialDays == [])
        #expect(abs(estimate.meanIntakeKcal - (7 * 2200 + 350) / 8) < 1e-9)
        // A day at half the median or more is not partial either.
        let half = try AdaptiveTDEE.estimate(
            history: history(loggedOffsets: logged, extra: [5: (1100, 3, false)]), endDay: end,
        ).get()
        #expect(half.loggedDays == 8 && half.partialDaysLeftOut == 0)
    }

    @Test func `uniformly low or mixed windows never lose all their days`() throws {
        // Every day at 800: all are equally "low", none is partial.
        let low = Simulation(tdee: 2500, eaten: { _ in 2500 }, logged: { _ in 800 })
        let estimate = try AdaptiveTDEE.estimate(history: low.history(), endDay: end).get()
        #expect(estimate.loggedDays == 14 && estimate.partialDaysLeftOut == 0)
        #expect(estimate.underLoggingSuspected == false) // no baseline given

        // Half the days at 900, half at 2,200: the median is 1,550, nothing is below 775.
        let mixed = Simulation(tdee: 2500, eaten: { _ in 2200 }, logged: { $0.isMultiple(of: 2) ? 900 : 2200 })
        #expect(try AdaptiveTDEE.estimate(history: mixed.history(), endDay: end).get().partialDaysLeftOut == 0)

        // The rule itself: at least half of the days are at or above the median, so most can go but never all.
        let days = (0 ..< 9).map { TDEEDay(day: end.adding(days: -$0), kcalIn: $0 < 5 ? 100 : 2000, entryCount: 3, isComplete: false) }
        #expect(AdaptiveTDEE.partialDays(days).isEmpty) // median 100
        let skewed = (0 ..< 9).map { TDEEDay(day: end.adding(days: -$0), kcalIn: $0 < 4 ? 100 : 2000, entryCount: 3, isComplete: false) }
        #expect(AdaptiveTDEE.partialDays(skewed).count == 4) // median 2,000
        #expect(AdaptiveTDEE.partialDays([]).isEmpty)
        let zeros = (0 ..< 3).map { TDEEDay(day: end.adding(days: -$0), kcalIn: 0, entryCount: 3, isComplete: false) }
        #expect(AdaptiveTDEE.partialDays(zeros).isEmpty)
    }

    @Test func `estimates stored before these fields decode with defaults`() throws {
        let estimate = try AdaptiveTDEE.estimate(history: history(loggedOffsets: Array(0 ..< 14)), endDay: end).get()
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(estimate)) as? [String: Any])
        #expect(json["weightMethod"] as? String == "trend")
        json["weightMethod"] = nil
        json["partialDays"] = nil
        let old = try JSONDecoder().decode(TDEEEstimate.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.weightMethod == nil && old.partialDays == nil)
        #expect(old.resolvedWeightMethod == .trend && old.partialDaysLeftOut == 0)
        #expect(TDEEWeightMethod.allCases.allSatisfy { !$0.explanation.isEmpty })
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
