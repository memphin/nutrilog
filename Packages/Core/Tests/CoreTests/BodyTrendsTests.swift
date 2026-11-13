import Foundation
import Testing
@testable import Core

private func close(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) < tolerance
}

struct WeightTrendTests {
    let zagreb = HealthFixtures.zagreb

    @Test func `alpha is two over N plus one`() {
        #expect(WeightTrend.alpha(days: 7) == 0.25)
        #expect(WeightTrend.alpha(days: 1) == 1)
    }

    @Test func `trend starts at the first weigh-in and moves by alpha`() {
        let weights: [LocalDay: Double] = [day("2026-11-01"): 80, day("2026-11-02"): 80.8, day("2026-11-03"): 80.4]
        let trend = WeightTrend.trendByDay(weights, through: day("2026-11-03"), alpha: 0.25)
        #expect(trend[day("2026-11-01")] == 80)
        #expect(close(trend[day("2026-11-02")], 80.2)) // 80 + 0.25 × 0.8
        #expect(close(trend[day("2026-11-03")], 80.25)) // 80.2 + 0.25 × 0.2
        #expect(trend.count == 3)
    }

    @Test func `missing days carry the trend forward`() {
        let weights: [LocalDay: Double] = [day("2026-11-01"): 80, day("2026-11-04"): 81]
        let trend = WeightTrend.trendByDay(weights, through: day("2026-11-06"), alpha: 0.25)
        #expect(trend[day("2026-11-02")] == 80)
        #expect(trend[day("2026-11-03")] == 80)
        // Three days after the previous weigh-in: moved by 1 − 0.75³ = 57.8 % of the difference, not 25 %.
        #expect(close(trend[day("2026-11-04")], 80 + (1 - 0.421875) * 1))
        #expect(close(trend[day("2026-11-06")], 80.578125))
        #expect(trend[day("2026-10-31")] == nil)
    }

    @Test func `trend of nothing or of future days is empty`() {
        #expect(WeightTrend.trendByDay([:], through: day("2026-11-01")).isEmpty)
        #expect(WeightTrend.trendByDay([day("2026-11-05"): 80], through: day("2026-11-01")).isEmpty)
    }

    @Test func `a constant weight has a constant trend`() {
        var weights: [LocalDay: Double] = [:]
        for offset in 0 ..< 20 {
            weights[day("2026-11-20").adding(days: -offset)] = 75.5
        }
        let trend = WeightTrend.trendByDay(weights, through: day("2026-11-20"))
        #expect(trend.values.allSatisfy { close($0, 75.5) })
    }

    @Test func `summary has latest, trend and 7-day change`() throws {
        var weights: [DayWeight] = []
        // One kilo less every day for 10 days, from 90 kg on Nov 1.
        for offset in 0 ..< 10 {
            weights.append(DayWeight(
                day: day("2026-11-01").adding(days: offset),
                kg: 90 - Double(offset),
                bodyFatPct: nil,
                isManual: false,
            ))
        }
        let summary = try #require(WeightTrend.summary(weights, today: day("2026-11-10")))
        #expect(summary.latestKg == 81)
        #expect(summary.latest.day == day("2026-11-10"))
        let trend = WeightTrend.trendByDay(WeightTrend.samples(weights), through: day("2026-11-10"))
        #expect(summary.trendKg == trend[day("2026-11-10")])
        let expected = try #require(trend[day("2026-11-10")]) - #require(trend[day("2026-11-03")])
        #expect(close(summary.trendChange7d, expected))
        #expect(try #require(summary.trendChange7d) < 0)
    }

    @Test func `summary without a week of history has no change`() throws {
        let weights = [DayWeight(day: day("2026-11-08"), kg: 80, bodyFatPct: nil, isManual: true)]
        let summary = try #require(WeightTrend.summary(weights, today: day("2026-11-10")))
        #expect(summary.trendKg == 80)
        #expect(summary.trendChange7d == nil)
        #expect(WeightTrend.summary([], today: day("2026-11-10")) == nil)
        // Body fat only: no weight to summarize.
        #expect(WeightTrend.summary(
            [DayWeight(day: day("2026-11-08"), kg: nil, bodyFatPct: 18, isManual: false)],
            today: day("2026-11-10"),
        ) == nil)
    }
}

struct WeightReconcilerTests {
    let zagreb = HealthFixtures.zagreb

    @Test func `manual weight wins over Health for its day`() {
        let health = [
            DailyHealthMetrics(day: day("2026-11-08"), weightKg: 81, bodyFatPct: 19),
            DailyHealthMetrics(day: day("2026-11-09"), weightKg: 80.5, bodyFatPct: 18.5),
        ]
        // The 07:00 weigh-in was entered last (a correction made in the evening).
        let manual = [
            ManualWeight(measuredAt: time("2026-11-09 18:00", zagreb), kg: 81.2, enteredAt: time("2026-11-09 18:00", zagreb)),
            ManualWeight(measuredAt: time("2026-11-09 07:00", zagreb), kg: 80.2, enteredAt: time("2026-11-09 19:00", zagreb)),
        ]
        let days = WeightReconciler.daily(health: health, manual: manual, calendar: zagreb)
        #expect(days.map(\.day) == [day("2026-11-08"), day("2026-11-09")])
        #expect(days[0] == DayWeight(day: day("2026-11-08"), kg: 81, bodyFatPct: 19, isManual: false))
        // Latest entered manual of the day; body fat falls back to Health's when the manual entries have none.
        #expect(days[1] == DayWeight(day: day("2026-11-09"), kg: 80.2, bodyFatPct: 18.5, isManual: true))
        // Without entry times, the later measurement counts as entered later.
        let plain = manual.map { ManualWeight(measuredAt: $0.measuredAt, kg: $0.kg) }
        #expect(WeightReconciler.daily(health: [], manual: plain, calendar: zagreb).first?.kg == 81.2)
    }

    @Test func `manual body fat wins and days are local`() {
        let manual = [
            ManualWeight(
                measuredAt: time("2026-11-09 00:30", zagreb),
                kg: 80,
                bodyFatPct: nil,
                enteredAt: time("2026-11-09 09:00", zagreb),
            ),
            ManualWeight(measuredAt: time("2026-11-09 08:00", zagreb), kg: 81, bodyFatPct: 17, enteredAt: time("2026-11-09 08:00", zagreb)),
        ]
        let health = [DailyHealthMetrics(day: day("2026-11-09"), bodyFatPct: 19)]
        let days = WeightReconciler.daily(health: health, manual: manual, calendar: zagreb)
        // The 00:30 entry was made last and wins; its missing body fat comes from the other manual entry.
        #expect(days == [DayWeight(day: day("2026-11-09"), kg: 80, bodyFatPct: 17, isManual: true)])
        // 00:30 in Zagreb is still Nov 8 in New York.
        let ny = WeightReconciler.daily(health: [], manual: [manual[0]], calendar: HealthFixtures.newYork)
        #expect(ny.map(\.day) == [day("2026-11-08")])
    }

    @Test func `days without weight or fat are skipped`() {
        let health = [DailyHealthMetrics(day: day("2026-11-09"), steps: 100)]
        #expect(WeightReconciler.daily(health: health, manual: [], calendar: zagreb).isEmpty)
    }

    @Test func `own weight samples are not read back from Health`() {
        let own = HealthSource(name: "Vitalion", bundleIdentifier: "hr.ivanjuric.nutrilog")
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-10"), samples: [
            .bodyMass: [
                HealthQuantitySample(start: time("2026-11-09 07:00", zagreb), value: 80, source: own),
                HealthQuantitySample(start: time("2026-11-09 09:00", zagreb), value: 81, source: HealthFixtures.withings),
                HealthQuantitySample(start: time("2026-11-10 07:00", zagreb), value: 79, source: own),
            ],
            .bodyFatPercentage: [HealthQuantitySample(start: time("2026-11-10 07:00", zagreb), value: 17, source: own)],
        ])
        let rows = DailyMetricsAggregator.aggregate(batch, calendar: zagreb, excludingOwnSamplesFrom: [own.bundleIdentifier])
        #expect(rows[0].weightKg == 81)
        #expect(rows[0].sources[.weight] == "Withings")
        #expect(rows[1].weightKg == nil)
        #expect(rows[1].bodyFatPct == nil)
        // Merged with the manual entry that wrote those samples, each weigh-in counts once.
        let manual = [ManualWeight(measuredAt: time("2026-11-10 07:00", zagreb), kg: 79, bodyFatPct: 17)]
        let days = WeightReconciler.daily(health: rows, manual: manual, calendar: zagreb)
        #expect(days.map(\.kg) == [81, 79])
        #expect(days.map(\.isManual) == [false, true])
    }
}

struct MetricBaselineTests {
    @Test func `HRV deviation against the previous 30 days`() throws {
        var values: [LocalDay: Double] = [:]
        let today = day("2026-11-30")
        for offset in 1 ... 30 {
            values[today.adding(days: -offset)] = 50
        }
        values[today] = 44
        let comparison = try #require(MetricBaseline.compare(values, today: today))
        #expect(comparison.day == today)
        #expect(comparison.value == 44)
        #expect(comparison.average30 == 50)
        #expect(close(comparison.deviation, -0.12))
        #expect(comparison.deviationText == "12% below your 30-day average")
        // 7-day average: today's 44 and six days of 50.
        #expect(close(comparison.average7, (44 + 6 * 50) / 7))
    }

    @Test func `above, in line, and too little history`() throws {
        let today = day("2026-11-30")
        var values: [LocalDay: Double] = [:]
        for offset in 1 ... 7 {
            values[today.adding(days: -offset)] = 40
        }
        values[today] = 46
        #expect(try #require(MetricBaseline.compare(values, today: today)).deviationText == "15% above your 30-day average")
        values[today] = 40.1
        #expect(try #require(MetricBaseline.compare(values, today: today)).deviationText == "In line with your 30-day average")
        values[today.adding(days: -7)] = nil // six days of history: no baseline yet
        let short = try #require(MetricBaseline.compare(values, today: today))
        #expect(short.average30 == nil)
        #expect(short.deviation == nil)
        #expect(short.deviationText == nil)
    }

    @Test func `deviation text never traps on extreme values`() {
        let today = day("2026-11-30")
        let huge = BaselineComparison(day: today, value: 1e300, average7: 1e300, average30: 1e-300) // deviation = ∞
        #expect(huge.deviationText == nil)
        let large = BaselineComparison(day: today, value: 1e30, average7: 1e30, average30: 1)
        // Localized integers are written with the user's grouping ("9,223,…" / "9.223,…").
        #expect(large.deviationText?.hasPrefix("\(Int.max.formatted())% above") == true)
    }

    @Test func `uses the latest recent day and ignores stale or future values`() throws {
        let today = day("2026-11-30")
        let values: [LocalDay: Double] = [today.adding(days: -2): 60, today.adding(days: 1): 99, today.adding(days: -20): 10]
        let comparison = try #require(MetricBaseline.compare(values, today: today))
        #expect(comparison.day == today.adding(days: -2))
        #expect(comparison.value == 60)
        #expect(MetricBaseline.compare([today.adding(days: -8): 60], today: today) == nil)
        #expect(MetricBaseline.compare([:], today: today) == nil)
    }
}
