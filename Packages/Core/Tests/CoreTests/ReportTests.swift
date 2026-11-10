import Foundation
import Testing
@testable import Core

struct AdherenceTests {
    @Test func `bands at 5 and 15 percent`() {
        #expect(Adherence.band(kcal: 2000, targetKcal: 2000) == .onTarget)
        #expect(Adherence.band(kcal: 2100, targetKcal: 2000) == .onTarget) // exactly +5 %
        #expect(Adherence.band(kcal: 1900, targetKcal: 2000) == .onTarget)
        #expect(Adherence.band(kcal: 2101, targetKcal: 2000) == .near)
        #expect(Adherence.band(kcal: 1700, targetKcal: 2000) == .near) // exactly −15 %
        #expect(Adherence.band(kcal: 2300, targetKcal: 2000) == .near)
        #expect(Adherence.band(kcal: 2301, targetKcal: 2000) == .off)
        #expect(Adherence.band(kcal: 900, targetKcal: 2000) == .off)
        #expect(Adherence.band(kcal: nil, targetKcal: 2000) == .notLogged)
        #expect(Adherence.band(kcal: 1800, targetKcal: nil) == .noTarget)
        #expect(Adherence.band(kcal: 1800, targetKcal: 0) == .noTarget)
        #expect(Adherence.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func `timeline picks the value in effect on a day`() throws {
        let timeline = try EffectiveTimeline([
            (from: #require(LocalDay("2026-10-01")), value: 2200.0),
            (from: #require(LocalDay("2026-11-01")), value: 2000.0),
            (from: #require(LocalDay("2026-09-01")), value: 2400.0),
        ])
        #expect(try timeline.value(on: #require(LocalDay("2026-08-31"))) == nil)
        #expect(try timeline.value(on: #require(LocalDay("2026-09-01"))) == 2400)
        #expect(try timeline.value(on: #require(LocalDay("2026-10-15"))) == 2200)
        #expect(try timeline.value(on: #require(LocalDay("2026-10-31"))) == 2200)
        #expect(try timeline.value(on: #require(LocalDay("2026-11-01"))) == 2000)
        #expect(try timeline.value(on: #require(LocalDay("2027-05-01"))) == 2000)
        #expect(try EffectiveTimeline<Double>([]).value(on: #require(LocalDay("2026-11-01"))) == nil)
    }

    @Test func `week and month helpers`() throws {
        let monday = try #require(LocalDay("2026-11-09"))
        #expect(monday.weekStart() == monday)
        #expect(LocalDay("2026-11-15")?.weekStart() == monday) // Sunday belongs to the week that started Monday
        #expect(try LocalDay("2026-11-15")?.weekStart(firstWeekday: 1) == #require(LocalDay("2026-11-15")))
        #expect(try LocalDay("2026-11-14")?.weekStart(firstWeekday: 1) == #require(LocalDay("2026-11-08")))
        #expect(try LocalDay("2026-11-30")?.monthStart == #require(LocalDay("2026-11-01")))
        #expect(try LocalDay("2026-11-30")?.addingMonths(2) == #require(LocalDay("2027-01-01")))
        #expect(try LocalDay("2026-01-15")?.addingMonths(-1) == #require(LocalDay("2025-12-01")))
        #expect(try LocalDay("2026-03-31")?.addingMonths(-25) == #require(LocalDay("2024-02-01")))
        #expect(LocalDay("2024-02-10")?.daysInMonth == 29)
        #expect(LocalDay("2026-02-10")?.daysInMonth == 28)
        #expect(LocalDay("2026-12-31")?.daysInMonth == 31)
    }
}

struct WeeklyReportTests {
    let monday = LocalDay("2026-11-02")!

    private func week(_ kcal: [Double?], target: Double? = 2000) -> [DayStats] {
        kcal.enumerated().map { index, value in
            DayStats(
                day: monday.adding(days: index),
                intake: value.map { Nutrients(kcal: $0, proteinG: $0 / 20, carbsG: $0 / 10, fatG: $0 / 30) },
                entryCount: value == nil ? 0 : 5, targetKcal: target,
                steps: index < 5 ? 8000 + index * 1000 : nil, sleepMin: 420 + index * 10,
                waterMl: index == 0 ? 2000 : nil, trendKg: 80 - 0.1 * Double(index),
            )
        }
    }

    @Test func `averages are over the days that have a value`() {
        let report = WeeklyReport(days: week([1900, 2100, nil, 2500, 2000, nil, 1500]), trendBefore: 80.1, expenditureKcal: 2400)
        #expect(report.start == monday)
        #expect(report.end == monday.adding(days: 6))
        #expect(report.loggedDays == 5)
        #expect(report.averageIntake?.kcal == 2000)
        #expect(report.averageIntake?.proteinG == 100)
        #expect(report.averageTargetKcal == 2000)
        #expect(report.averageSteps == 10000) // 8,9,10,11,12 thousand over 5 days
        #expect(report.averageSleepMin == 450)
        #expect(report.averageWaterMl == 2000)
        #expect(report.balanceKcal == -400)
    }

    @Test func `best and worst day by distance from the target`() {
        let report = WeeklyReport(days: week([1900, 2100, nil, 2500, 2010, nil, 1400]))
        #expect(report.bestDay?.day == monday.adding(days: 4))
        #expect(report.bestDay?.difference == 10)
        #expect(report.worstDay?.day == monday.adding(days: 6))
        #expect(report.worstDay?.difference == -600)

        let single = WeeklyReport(days: week([nil, nil, 1800, nil, nil, nil, nil]))
        #expect(single.bestDay?.day == monday.adding(days: 2))
        #expect(single.worstDay == nil)

        let noTarget = WeeklyReport(days: week([1900, 2100, nil, nil, nil, nil, nil], target: nil))
        #expect(noTarget.bestDay == nil)
        #expect(noTarget.averageTargetKcal == nil)
    }

    @Test func `trend change uses the day before the week when known`() throws {
        let days = week([2000, 2000, 2000, 2000, 2000, 2000, 2000])
        #expect(try abs(#require(WeeklyReport(days: days, trendBefore: 80.1).trendChangeKg) - -0.7) < 1e-9)
        #expect(try abs(#require(WeeklyReport(days: days).trendChangeKg) - -0.6) < 1e-9)
        #expect(WeeklyReport(days: days).trendEndKg == 79.4)
        var noTrend = days
        for index in noTrend.indices {
            noTrend[index].trendKg = nil
        }
        #expect(WeeklyReport(days: noTrend).trendChangeKg == nil)
        noTrend[3].trendKg = 80
        #expect(WeeklyReport(days: noTrend).trendChangeKg == nil) // one point is no change
    }

    @Test func `empty week`() {
        let report = WeeklyReport(days: week([nil, nil, nil, nil, nil, nil, nil]))
        #expect(report.loggedDays == 0)
        #expect(report.averageIntake == nil)
        #expect(report.balanceKcal == nil)
        #expect(report.bestDay == nil)
        #expect(Stats.mean([nil, nil]) == nil)
        #expect(Stats.mean([1, nil, 3]) == 2)
        #expect(report.days[0].adherence == .notLogged)
    }
}

struct FoodDuplicatesTests {
    @Test func `normalizes case, diacritics, punctuation and spaces`() {
        #expect(FoodDuplicates.normalize("  Čokolada   MILKA! ") == "cokolada milka")
        #expect(FoodDuplicates.normalize("Jogurt 2,8%") == "jogurt 2 8")
        #expect(FoodDuplicates.normalize(nil) == "")
        #expect(FoodDuplicates.key(name: "Milk", brand: "Dukat") == "milk|dukat")
        #expect(FoodDuplicates.key(name: "Milk", brand: nil) == "milk|")
        #expect(FoodDuplicates.key(name: " -- ", brand: "X") == "")
    }

    @Test func `groups by barcode or by name and brand`() {
        let foods = [
            FoodDuplicates.Candidate(id: "a", name: "Milk 2.8%", brand: "Dukat", barcodes: ["3850000000017"]),
            FoodDuplicates.Candidate(id: "b", name: "Oats", brand: nil, barcodes: []),
            FoodDuplicates.Candidate(id: "c", name: "milk 2,8 %", brand: "DUKAT", barcodes: []),
            FoodDuplicates.Candidate(id: "d", name: "Svježe mlijeko", brand: "Dukat", barcodes: ["3850000000017"]),
            FoodDuplicates.Candidate(id: "e", name: "Oats", brand: "Quaker", barcodes: []),
            FoodDuplicates.Candidate(id: "f", name: "OATS", brand: "", barcodes: []),
        ]
        // a–c by name, a–d by barcode → one group; b–f by name (no brand); e differs by brand.
        #expect(FoodDuplicates.groups(foods) == [["a", "c", "d"], ["b", "f"]])
        #expect(FoodDuplicates.groups([]).isEmpty)
        #expect(FoodDuplicates.groups([foods[0]]).isEmpty)
    }

    @Test func `frecency halves every 30 days`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Frecency.score(useCount: 4, lastUsedAt: now, now: now) == 4)
        #expect(abs(Frecency.score(useCount: 4, lastUsedAt: now.addingTimeInterval(-30 * 86400), now: now) - 2) < 1e-9)
        #expect(Frecency.score(useCount: 0, lastUsedAt: now, now: now) == 0)
        #expect(Frecency.score(useCount: 3, lastUsedAt: nil, now: now) == 0)
        // Ten uses two months ago still beat one use today.
        #expect(Frecency.score(useCount: 10, lastUsedAt: now.addingTimeInterval(-60 * 86400), now: now)
            > Frecency.score(useCount: 1, lastUsedAt: now, now: now))
    }
}
