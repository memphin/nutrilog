import Core
import Foundation
import Testing
@testable import Vitalion

/// Correlations (FR-53): which days pair up, weekly buckets, what is left out, and how the cards read.
struct CorrelationPairTests {
    /// Thursday.
    let today = LocalDay("2026-11-12")!
    let meal = Nutrients(kcal: 2000, proteinG: 120, carbsG: 220, fatG: 70)

    /// `count` empty days ending on `last`, oldest first.
    func days(_ count: Int, endingOn last: LocalDay) -> [DayStats] {
        (0 ..< count).map { DayStats(day: last.adding(days: $0 - count + 1)) }
    }

    func pairs(_ spec: CorrelationSpec, _ stats: [DayStats], in range: ClosedRange<LocalDay>, firstWeekday: Int = 2) -> [CorrelationPair] {
        CorrelationPairBuilder.pairs(spec, stats: stats, in: range, unit: .kcal, firstWeekday: firstWeekday)
    }

    // MARK: Daily pairs

    @Test func `next-day pairs take x from a day and y from the day after`() {
        var stats = days(5, endingOn: today.previous)
        for index in stats.indices {
            stats[index].waterMl = Double(1000 + 100 * index)
            stats[index].hrvMs = Double(40 + index)
        }
        let range = stats[0].day ... stats[4].day
        let next = pairs(CorrelationSpec(x: .hydration, y: .hrv, lag: .nextDay), stats, in: range)
        // Four pairs: the last day's partner would be today, outside the range.
        #expect(next.map(\.day) == stats.prefix(4).map(\.day))
        #expect(next.map(\.x) == [1.0, 1.1, 1.2, 1.3]) // litres
        #expect(next.map(\.y) == [41, 42, 43, 44])

        let same = pairs(CorrelationSpec(x: .hydration, y: .hrv, lag: .sameDay), stats, in: range)
        #expect(same.map(\.y) == [40, 41, 42, 43, 44])
    }

    @Test func `sleep the next day is the night after the day`() {
        var stats = days(3, endingOn: today.previous)
        stats[0].waterMl = 2500
        stats[1].sleepMin = 450 // recorded the next morning: the night after day 0
        let range = stats[0].day ... stats[2].day
        let result = pairs(CorrelationCard.hydrationSleep.spec, stats, in: range)
        #expect(result == [CorrelationPair(day: stats[0].day, x: 2.5, y: 7.5)])
    }

    @Test func `days missing either value are left out`() {
        var stats = days(4, endingOn: today.previous)
        stats[0].steps = 8000
        stats[0].restingHR = 55
        stats[1].steps = 9000 // no resting heart rate
        stats[2].restingHR = 58 // no steps
        stats[3].steps = 10000
        stats[3].restingHR = 52
        let result = pairs(CorrelationSpec(x: .steps, y: .restingHeartRate), stats, in: stats[0].day ... stats[3].day)
        #expect(result.map(\.day) == [stats[0].day, stats[3].day])
    }

    @Test func `partly logged days are left out of intake, by the maintenance estimate's rule`() {
        var stats = days(4, endingOn: today.previous)
        for index in stats.indices {
            stats[index].intake = meal
            stats[index].sleepMin = 420
        }
        stats[0].entryCount = 3 // logged
        stats[1].entryCount = 2 // partly logged
        stats[2].entryCount = 1
        stats[2].isComplete = true // marked fully logged
        stats[3].entryCount = 0 // nothing
        stats[3].intake = nil
        let result = pairs(CorrelationSpec(x: .sleep, y: .calories), stats, in: stats[0].day ... stats[3].day)
        #expect(result.map(\.day) == [stats[0].day, stats[2].day])
        #expect(result.allSatisfy { $0.y == 2000 && $0.x == 7 })
        // Macros follow the same rule.
        let protein = pairs(CorrelationSpec(x: .protein, y: .sleep), stats, in: stats[0].day ... stats[3].day)
        #expect(protein.map(\.day) == [stats[0].day, stats[2].day])
        #expect(protein.first?.x == 120)
    }

    @Test func `energy is shown in the chosen unit`() {
        var stats = days(1, endingOn: today.previous)
        stats[0].intake = meal
        stats[0].entryCount = 4
        stats[0].activeKcal = 500
        stats[0].basalKcal = 1700
        let range = stats[0].day ... stats[0].day
        let spec = CorrelationSpec(x: .totalEnergy, y: .calories)
        let kcal = CorrelationPairBuilder.pairs(spec, stats: stats, in: range, unit: .kcal, firstWeekday: 2)
        let kilojoules = CorrelationPairBuilder.pairs(spec, stats: stats, in: range, unit: .kilojoules, firstWeekday: 2)
        #expect(kcal.first?.x == 2200 && kcal.first?.y == 2000)
        #expect(abs((kilojoules.first?.x ?? 0) - 2200 * 4.184) < 1e-9)
        #expect(pairs(CorrelationSpec(x: .activeEnergy, y: .calories), stats, in: range).first?.x == 500)
    }

    @Test func `today is never paired: the period ends yesterday`() throws {
        var stats = days(30, endingOn: today)
        for index in stats.indices {
            stats[index].waterMl = 2000 + Double(index)
            stats[index].hrvMs = 40 + Double(index)
        }
        let period = CorrelationPeriod.threeMonths.days(before: today)
        #expect(period.upperBound == today.previous)
        #expect(period.lowerBound == today.adding(days: -90))
        let analysis = CorrelationAnalysis.make(
            CorrelationCard.hydrationHRV.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
        // Yesterday's hydration would pair with today's HRV: left out, like today's own hydration.
        #expect(analysis.pairs.count == 28)
        #expect(try #require(analysis.pairs.last).day == today.adding(days: -2))
        #expect(!analysis.pairs.contains { $0.day >= today.previous })
    }

    // MARK: Weekly pairs

    /// Days from Monday 2026-10-05 through yesterday (Wednesday 2026-11-11): steps rise by day, the trend falls faster
    /// and faster (so the trend's start and end days matter).
    func weeklyStats() -> [DayStats] {
        let first = LocalDay("2026-10-05")!
        return (0 ... first.days(until: today.previous)).map { index in
            var day = DayStats(day: first.adding(days: index))
            day.steps = 5000 + 100 * index
            day.trendKg = 80 - 0.001 * Double(index * index)
            day.intake = meal
            day.entryCount = 3
            return day
        }
    }

    func trend(on day: LocalDay) -> Double {
        let index = Double(LocalDay("2026-10-05")!.days(until: day))
        return 80 - 0.001 * index * index
    }

    @Test func `weeks follow the first weekday and only whole weeks of the period count`() {
        let stats = weeklyStats()
        let range = LocalDay("2026-10-07")! ... today.previous // Wednesday to Wednesday
        let spec = CorrelationCard.stepsWeight.spec
        // Monday weeks: 12, 19, 26 Oct and 2 Nov (the week of 9 Nov is not over; 5 Oct starts before the period).
        let monday = pairs(spec, stats, in: range, firstWeekday: 2)
        #expect(monday.map(\.day.isoString) == ["2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02"])
        // Sunday weeks: 11, 18, 25 Oct and 1 Nov.
        let sunday = pairs(spec, stats, in: range, firstWeekday: 1)
        #expect(sunday.map(\.day.isoString) == ["2026-10-11", "2026-10-18", "2026-10-25", "2026-11-01"])
    }

    @Test func `a week pairs its average with the trend change from the day before it to its last day`() throws {
        let stats = weeklyStats()
        let range = LocalDay("2026-10-07")! ... today.previous
        let week = try #require(pairs(CorrelationCard.stepsWeight.spec, stats, in: range).first)
        let start = LocalDay("2026-10-12")!
        // Steps on 12–18 Oct: indices 7…13 → 5,700 … 6,300, mean 6,000.
        #expect(week.x == 6000)
        #expect(abs(week.y - (trend(on: start.adding(days: 6)) - trend(on: start.previous))) < 1e-12)
    }

    @Test func `a week needs four days with a value and a trend at both ends`() {
        var stats = weeklyStats()
        let range = LocalDay("2026-10-12")! ... LocalDay("2026-10-25")!
        // Week 1 (12–18 Oct): only four days of steps → still counts. Week 2 (19–25 Oct): three → left out.
        for index in stats.indices where (12 ... 14).contains(stats[index].day.day) || (19 ... 22).contains(stats[index].day.day) {
            stats[index].steps = nil
        }
        #expect(pairs(CorrelationCard.stepsWeight.spec, stats, in: range).map(\.day.isoString) == ["2026-10-12"])

        // No trend before the week: no change to measure.
        var noTrend = weeklyStats()
        for index in noTrend.indices where noTrend[index].day < LocalDay("2026-10-12")! {
            noTrend[index].trendKg = nil
        }
        #expect(pairs(CorrelationCard.stepsWeight.spec, noTrend, in: range).map(\.day.isoString) == ["2026-10-19"])
    }

    @Test func `weekly calories average only fully logged days`() throws {
        var stats = weeklyStats()
        let range = LocalDay("2026-10-12")! ... LocalDay("2026-10-18")!
        // Two partly logged days with little energy would drag the week's mean down.
        for index in stats.indices where [12, 13].contains(stats[index].day.day) {
            stats[index].entryCount = 1
            stats[index].intake = Nutrients(kcal: 300, proteinG: 10, carbsG: 40, fatG: 10)
        }
        let week = try #require(pairs(CorrelationCard.caloriesWeight.spec, stats, in: range).first)
        #expect(week.x == 2000)
        // With four partly logged days only three remain: the week is left out.
        for index in stats.indices where [14, 15].contains(stats[index].day.day) {
            stats[index].entryCount = 2
        }
        #expect(pairs(CorrelationCard.caloriesWeight.spec, stats, in: range).isEmpty)
    }

    // MARK: Specs

    @Test func `the four cards`() {
        #expect(CorrelationCard.hydrationHRV.spec == CorrelationSpec(x: .hydration, y: .hrv, lag: .nextDay, granularity: .daily))
        #expect(CorrelationCard.hydrationSleep.spec == CorrelationSpec(x: .hydration, y: .sleep, lag: .nextDay, granularity: .daily))
        #expect(CorrelationCard.stepsWeight.spec == CorrelationSpec(x: .steps, y: .weightTrendChange, granularity: .weekly))
        #expect(CorrelationCard.caloriesWeight.spec == CorrelationSpec(x: .calories, y: .weightTrendChange, granularity: .weekly))
        #expect(CorrelationCard.hydrationHRV.spec.minimumPairs == 14)
        #expect(CorrelationCard.stepsWeight.spec.minimumPairs == 6)
    }

    @Test func `weight-trend change is weekly only, and weeks compare the same week`() {
        let daily = CorrelationSpec(x: .steps, y: .weightTrendChange, lag: .nextDay, granularity: .daily).normalized
        #expect(daily.granularity == .weekly && daily.lag == .sameDay)
        #expect(CorrelationSpec(x: .weightTrendChange, y: .sleep).normalized.granularity == .weekly)
        #expect(CorrelationSpec(x: .steps, y: .sleep, lag: .nextDay).normalized == CorrelationSpec(x: .steps, y: .sleep, lag: .nextDay))
        #expect(CorrelationSpec(x: .steps, y: .sleep, lag: .nextDay, granularity: .weekly).normalized.lag == .sameDay)
        #expect(CorrelationMetric.weightTrendChange.isWeeklyOnly && !CorrelationMetric.steps.isWeeklyOnly)
        // Daily pairs of a weekly-only spec are none: the builder normalizes first.
        var stats = weeklyStats()
        stats[0].trendKg = 80
        #expect(!pairs(CorrelationSpec(x: .steps, y: .weightTrendChange), stats, in: stats[0].day ... today.previous).isEmpty)
    }

    @Test func `the explorer offers every measure but caffeine and training days`() {
        #expect(CorrelationMetric.allCases == [
            .calories, .protein, .carbs, .fat, .steps, .totalEnergy, .activeEnergy, .sleep, .hydration, .hrv,
            .restingHeartRate, .weightTrendChange,
        ])
    }
}

/// What the cards say.
struct CorrelationTextTests {
    let today = LocalDay("2026-11-12")!

    /// `count` days ending the day before yesterday: hydration rising, next-day HRV following it (`slope` ms per litre).
    func hydrationHRV(_ count: Int, slope: Double = 10) -> CorrelationAnalysis {
        let stats = (0 ..< count + 1).map { index -> DayStats in
            var day = DayStats(day: today.adding(days: index - count - 1))
            day.waterMl = 1000 + 100 * Double(index)
            day.hrvMs = 40 + slope * (0.9 + 0.1 * Double(index))
            return day
        }
        return CorrelationAnalysis.make(
            CorrelationCard.hydrationHRV.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
    }

    @Test func `too few days say how many are needed and how many there are`() {
        let analysis = hydrationHRV(9)
        #expect(analysis.result.count == 9)
        #expect(!analysis.result.hasEnoughData)
        #expect(CorrelationText.sentence(analysis) == "Needs 14 days with both values. You have 9.")
        #expect(CorrelationText.strength(analysis.result) == "Not enough data")
    }

    @Test func `too few weeks say so in weeks`() {
        let stats = (0 ..< 20).map { index -> DayStats in
            var day = DayStats(day: today.adding(days: index - 20))
            day.steps = 8000
            day.trendKg = 80
            return day
        }
        let analysis = CorrelationAnalysis.make(
            CorrelationCard.stepsWeight.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
        #expect(analysis.result.count == 2)
        #expect(CorrelationText.sentence(analysis) == "Needs 6 weeks with both values. You have 2.")
        let one = CorrelationAnalysis.make(
            CorrelationCard.stepsWeight.spec, period: .threeMonths, stats: Array(stats.suffix(11)), today: today, unit: .kcal,
            firstWeekday: 2,
        )
        #expect(CorrelationText.sentence(one) == "Needs 6 weeks with both values. You have 1.")
    }

    @Test func `a rising link reads as higher, with litres and milliseconds`() {
        let analysis = hydrationHRV(15)
        #expect(analysis.result.hasEnoughData)
        #expect(CorrelationText.strength(analysis.result) == "Strong positive link")
        #expect(CorrelationText.basedOn(analysis) == "Based on 15 days")
        // Lowest third: 1.0–1.4 L (under 1.5 L); highest third: 2.0–2.4 L. HRV means 1 ms per 100 ml apart → 10 ms higher.
        let sentence = CorrelationText.sentence(analysis)
        #expect(sentence.hasPrefix("On days you drank 2\(decimalSeparator)0 L or more, your HRV the next day was 10 ms higher than"))
        #expect(sentence.hasSuffix("on days under 1\(decimalSeparator)5 L."))
    }

    @Test func `a falling link reads as lower`() {
        let analysis = hydrationHRV(15, slope: -10)
        #expect(CorrelationText.strength(analysis.result) == "Strong negative link")
        #expect(CorrelationText.sentence(analysis).contains("your HRV the next day was 10 ms lower than"))
    }

    @Test func `no difference reads as about the same`() {
        let analysis = hydrationHRV(15, slope: 0)
        #expect(CorrelationText.strength(analysis.result) == "No clear link")
        #expect(CorrelationText.sentence(analysis).contains("your HRV the next day was about the same as on days under"))
    }

    @Test func `sleep reads as longer or shorter, in hours and minutes`() {
        let stats = (0 ..< 16).map { index -> DayStats in
            var day = DayStats(day: today.adding(days: index - 16))
            day.waterMl = 1000 + 100 * Double(index)
            day.sleepMin = 400 - 3 * index
            return day
        }
        let analysis = CorrelationAnalysis.make(
            CorrelationCard.hydrationSleep.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
        // Pairs: water of days 0–14 with the sleep of days 1–15; the thirds are ten days apart → 30 min shorter.
        #expect(CorrelationText.sentence(analysis).contains("your sleep that night was 30min shorter than on days under"))
    }

    @Test func `weekly weight sentences give both changes`() {
        let first = LocalDay("2026-09-07")! // a Monday; nine whole weeks to 8 Nov
        let stats = (-1 ..< 63).map { index -> DayStats in
            var day = DayStats(day: first.adding(days: index))
            guard index >= 0 else {
                day.trendKg = 80
                return day
            }
            let week = index / 7
            day.steps = 6000 + 1000 * week
            // Losing 0.1 kg more per week for each extra 1,000 steps.
            day.trendKg = 80 - 0.1 * Double(week * (week + 1)) / 2 - 0.1 * Double(week + 1) * Double(index % 7 + 1) / 7
            return day
        }
        let analysis = CorrelationAnalysis.make(
            CorrelationCard.stepsWeight.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
        #expect(analysis.result.count == 9)
        #expect(CorrelationText.basedOn(analysis) == "Based on 9 weeks")
        #expect(CorrelationText.strength(analysis.result) == "Strong negative link")
        // Thirds: 6,000–8,000 steps (weeks losing 0.1–0.3 kg) against 12,000–14,000 (0.7–0.9 kg).
        let sentence = CorrelationText.sentence(analysis)
        #expect(
            sentence == "In weeks you averaged \(whole(12000)) steps or more, your weight trend changed by −0\(decimalSeparator)8 kg/week, "
                + "vs −0\(decimalSeparator)2 kg/week in weeks under \(whole(9000)) steps.",
        )
    }

    @Test func `weekly weight changes that read the same are about the same`() {
        let first = LocalDay("2026-09-07")!
        // Week w changes by −0.1 − 0.005·w kg: −0.10 to −0.14, all shown as −0.1 kg/week.
        func endOfWeek(_ week: Int) -> Double {
            80 - 0.1 * Double(week + 1) - 0.005 * Double(week * (week + 1)) / 2
        }
        let stats = (-1 ..< 63).map { index -> DayStats in
            var day = DayStats(day: first.adding(days: index))
            guard index >= 0 else {
                day.trendKg = 80
                return day
            }
            let week = index / 7
            let before = week == 0 ? 80 : endOfWeek(week - 1)
            day.steps = 6000 + 1000 * week
            day.trendKg = before + (endOfWeek(week) - before) * Double(index % 7 + 1) / 7
            return day
        }
        let analysis = CorrelationAnalysis.make(
            CorrelationCard.stepsWeight.spec, period: .threeMonths, stats: stats, today: today, unit: .kcal, firstWeekday: 2,
        )
        #expect(analysis.result.count == 9)
        #expect(CorrelationText.sentence(analysis) == "In weeks you averaged \(whole(12000)) steps or more, "
            + "your weight trend was about the same as in weeks under \(whole(9000)) steps.")
    }

    @Test func `croatian counts of days and weeks take three plural forms`() throws {
        let path = try #require(Bundle.main.path(forResource: "hr", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let croatian = Locale(identifier: "hr_HR")
        func weeks(_ count: Int) -> String {
            String(localized: "Based on \(count) weeks", bundle: bundle, locale: croatian)
        }
        #expect(weeks(1) == "Na temelju 1 tjedna")
        #expect(weeks(3) == "Na temelju 3 tjedna")
        #expect(weeks(12) == "Na temelju 12 tjedana")
        func needs(_ count: Int) -> String {
            String(localized: "Needs \(count) days with both values.", bundle: bundle, locale: croatian)
        }
        #expect(needs(14) == "Potrebno je 14 dana s obje vrijednosti.")
        #expect(needs(22) == "Potrebna su 22 dana s obje vrijednosti.")
        #expect(String(localized: "Needs \(6) weeks with both values.", bundle: bundle, locale: croatian)
            == "Potrebno je 6 tjedana s obje vrijednosti.")
    }

    @Test func `values carry their units`() {
        let sep = decimalSeparator
        #expect(CorrelationText.format(2, .hydration, unit: .kcal) == "2\(sep)0 L")
        // Litres to the nearest 50 ml: quarter litres stay exact, measured totals read like a bottle size.
        #expect(CorrelationText.format(1.75, .hydration, unit: .kcal) == "1\(sep)75 L")
        #expect(CorrelationText.format(2.29, .hydration, unit: .kcal) == "2\(sep)3 L")
        #expect(CorrelationText.format(1.84, .hydration, unit: .kcal) == "1\(sep)85 L")
        #expect(CorrelationText.format(0.85, .hydration, unit: .kcal) == "850 ml")
        #expect(CorrelationText.format(7 + 20.0 / 60, .sleep, unit: .kcal) == "7h 20min")
        #expect(CorrelationText.format(48.4, .hrv, unit: .kcal) == "48 ms")
        #expect(CorrelationText.format(2100, .calories, unit: .kilojoules) == "\(whole(2100)) kJ")
        #expect(CorrelationText.format(0.14, .weightTrendChange, unit: .kcal) == "+0\(sep)1 kg/week")
        #expect(CorrelationText.isNegligible(0.04, .weightTrendChange) && !CorrelationText.isNegligible(0.06, .weightTrendChange))
        #expect(CorrelationText.isNegligible(0.4 / 60, .sleep) && !CorrelationText.isNegligible(1.0 / 60, .sleep))
    }

    @Test func `axis titles name the unit once`() {
        #expect(CorrelationText.axisLabel(.hydration, unit: .kcal) == "Hydration (L)")
        #expect(CorrelationText.axisLabel(.calories, unit: .kilojoules) == "Calories (kJ)")
        #expect(CorrelationText.axisLabel(.steps, unit: .kcal) == "Steps")
    }

    @Test func `the scatter plot has a spoken summary`() {
        let analysis = hydrationHRV(15)
        let summary = CorrelationText.chartSummary(analysis)
        #expect(summary.contains("Hydration against HRV"))
        #expect(summary.contains("Strong positive link"))
        #expect(summary.contains("15 days"))
    }

    private func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private var decimalSeparator: String {
        Locale.current.decimalSeparator ?? "."
    }
}
