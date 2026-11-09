import Foundation
import Testing
@testable import Core

struct HealthFetchPlanTests {
    let zagreb = HealthFixtures.zagreb

    @Test func `plan intervals follow local midnights across DST`() {
        let plan = HealthFetchPlan(days: day("2026-03-28") ... day("2026-03-30"), calendar: zagreb)
        #expect(plan.dayInterval.start == time("2026-03-28 00:00"))
        #expect(plan.dayInterval.end == time("2026-03-31 00:00"))
        #expect(plan.dayInterval.duration == 255_600) // 24 + 23 + 24 h
        #expect(plan.sleepInterval.start == time("2026-03-27 18:00"))
        #expect(plan.sleepInterval.end == time("2026-03-30 18:00"))
        #expect(plan.allDays.map(\.isoString) == ["2026-03-28", "2026-03-29", "2026-03-30"])
    }

    @Test func `day containing a date`() {
        let plan = HealthFetchPlan(days: day("2026-10-25") ... day("2026-10-25"), calendar: zagreb)
        #expect(plan.dayInterval.duration == 90000) // 25 h
        #expect(plan.day(containing: time("2026-10-25 00:00")) == day("2026-10-25"))
        #expect(plan.day(containing: time("2026-10-25 23:59")) == day("2026-10-25"))
        #expect(plan.day(containing: time("2026-10-24 23:59")) == nil)
        #expect(plan.day(containing: time("2026-10-26 00:00")) == nil)
    }

    @Test func `local day helpers`() {
        let spring = day("2026-03-29")
        #expect(spring.dateInterval(calendar: zagreb).duration == 82800)
        #expect(spring.date(atHour: 9, calendar: zagreb).timeIntervalSince(spring.startDate(calendar: zagreb)) == 28800) // 8 h of real time
        #expect(spring.date(atHour: 2, calendar: zagreb) == time("2026-03-29 03:00")) // skipped hour moves forward
    }
}

struct DailyMetricsAggregatorTests {
    let zagreb = HealthFixtures.zagreb
    let watch = HealthFixtures.watch
    let withings = HealthFixtures.withings

    func aggregate(_ batch: HealthDataBatch, calendar: Calendar = HealthFixtures.zagreb) -> [LocalDay: DailyHealthMetrics] {
        Dictionary(uniqueKeysWithValues: DailyMetricsAggregator.aggregate(batch, calendar: calendar).map { ($0.day, $0) })
    }

    @Test func `one row per day, oldest first, empty when Health has nothing`() {
        let days = day("2026-11-07") ... day("2026-11-09")
        let rows = DailyMetricsAggregator.aggregate(HealthDataBatch(days: days), calendar: zagreb)
        #expect(rows.map(\.day.isoString) == ["2026-11-07", "2026-11-08", "2026-11-09"])
        let allEmpty = rows.allSatisfy(\.isEmpty)
        #expect(allEmpty)
        #expect(rows.allSatisfy { $0.sourceSummaryJSON == nil })
    }

    @Test func `cumulative statistics land on their local day, DST days included`() throws {
        let days = day("2026-03-28") ... day("2026-03-30")
        let contributions = [
            SourceContribution(source: HealthFixtures.iPhone, sum: 4000),
            SourceContribution(source: watch, sum: 7000),
        ]
        let batch = HealthDataBatch(days: days, statistics: [
            .steps: [
                dailyStatistic("2026-03-28", 9000.4, sources: contributions),
                dailyStatistic("2026-03-29", 8000.6, sources: contributions), // the 23 h day
                dailyStatistic("2026-03-31", 5000), // outside the range
            ],
            .activeEnergy: [dailyStatistic("2026-03-29", 512.5, sources: [SourceContribution(source: watch, sum: 512.5)])],
            .basalEnergy: [dailyStatistic("2026-03-29", 1690)],
            .dietaryWater: [dailyStatistic("2026-03-30", 1750, sources: [SourceContribution(source: HealthFixtures.healthApp, sum: 1750)])],
        ])
        let rows = aggregate(batch)
        let spring = try #require(rows[day("2026-03-29")])
        #expect(rows[day("2026-03-28")]?.steps == 9000)
        #expect(spring.steps == 8001) // the de-duplicated total, not 4000 + 7000
        #expect(spring.sources[.steps] == watch.name)
        #expect(spring.activeKcal == 512.5)
        #expect(spring.sources[.activeEnergy] == watch.name)
        #expect(spring.basalKcal == 1690)
        #expect(spring.sources[.basalEnergy] == nil) // no per-source breakdown available
        #expect(rows[day("2026-03-30")]?.waterMl == 1750)
        #expect(rows[day("2026-03-30")]?.sources[.water] == "Health")
        #expect(rows[day("2026-03-30")]?.steps == nil)
        #expect(rows.count == 3)
    }

    @Test func `water written by Nutrilog itself is not read back`() {
        let nutrilog = HealthSource(name: "Nutrilog", bundleIdentifier: "hr.ivanjuric.nutrilog", productType: "iPhone17,1")
        let other = HealthFixtures.healthApp
        let batch = HealthDataBatch(days: day("2026-11-08") ... day("2026-11-10"), statistics: [
            .dietaryWater: [
                // Ours + another app's: only the other app's water is kept.
                dailyStatistic("2026-11-08", 1250, sources: [
                    SourceContribution(source: nutrilog, sum: 750), SourceContribution(source: other, sum: 500),
                ]),
                // Only ours: no "other apps" water at all.
                dailyStatistic("2026-11-09", 600, sources: [SourceContribution(source: nutrilog, sum: 600)]),
                // Only another app's.
                dailyStatistic("2026-11-10", 330, sources: [SourceContribution(source: other, sum: 330)]),
            ],
            .steps: [dailyStatistic("2026-11-09", 100, sources: [SourceContribution(source: nutrilog, sum: 100)])],
        ])
        let rows = Dictionary(
            uniqueKeysWithValues: DailyMetricsAggregator.aggregate(
                batch, calendar: zagreb, excludingWaterFrom: ["hr.ivanjuric.nutrilog"],
            ).map { ($0.day, $0) },
        )
        #expect(rows[day("2026-11-08")]?.waterMl == 500)
        #expect(rows[day("2026-11-08")]?.sources[.water] == "Health")
        #expect(rows[day("2026-11-09")]?.waterMl == nil)
        #expect(rows[day("2026-11-09")]?.sources[.water] == nil)
        #expect(rows[day("2026-11-09")]?.steps == 100) // other metrics are not filtered
        #expect(rows[day("2026-11-10")]?.waterMl == 330)
        // Without the exclusion everything counts.
        #expect(aggregate(batch)[day("2026-11-08")]?.waterMl == 1250)
    }

    @Test func `excluded water never goes negative`() {
        let nutrilog = HealthSource(name: "Nutrilog", bundleIdentifier: "app", productType: nil)
        // Per-source sums are taken before de-duplication, so they can exceed the de-duplicated total.
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-09"), statistics: [
            .dietaryWater: [dailyStatistic("2026-11-09", 500, sources: [
                SourceContribution(source: nutrilog, sum: 600), SourceContribution(source: HealthFixtures.healthApp, sum: 200),
            ])],
        ])
        let rows = DailyMetricsAggregator.aggregate(batch, calendar: zagreb, excludingWaterFrom: ["app"])
        #expect(rows.first?.waterMl == 0)
    }

    @Test func `statistics are bucketed by the calendar's time zone`() {
        // A bucket from UTC midnight to midnight starts on 2026-11-08 in New York (19:00); its midpoint decides.
        let utcDay = day("2026-11-09").dateInterval(calendar: HealthFixtures.utc)
        let stat = CumulativeStatistic(start: utcDay.start, end: utcDay.end, sum: 100)
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-09"), statistics: [.steps: [stat]])
        #expect(aggregate(batch, calendar: HealthFixtures.utc)[day("2026-11-09")]?.steps == 100)
        #expect(aggregate(batch, calendar: HealthFixtures.newYork)[day("2026-11-09")]?.steps == 100)
    }

    @Test func `earliest weight of the day with body fat from the same measurement`() throws {
        let manual = HealthFixtures.healthApp
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-10"), samples: [
            .bodyMass: [
                quantity(83.1, at: "2026-11-09 20:00", manual),
                quantity(82.4, at: "2026-11-09 07:05", withings),
                quantity(82.9, at: "2026-11-10 07:10", withings),
            ],
            .bodyFatPercentage: [
                quantity(25.0, at: "2026-11-09 06:00", manual), // earlier, but another measurement
                quantity(18.2, at: "2026-11-09 07:05:30", withings),
                quantity(18.6, at: "2026-11-10 21:00", manual), // only body fat sample that day
            ],
        ])
        let rows = aggregate(batch)
        let first = try #require(rows[day("2026-11-09")])
        #expect(first.weightKg == 82.4)
        #expect(first.bodyFatPct == 18.2)
        #expect(first.sources[.weight] == "Withings")
        #expect(first.sources[.bodyFat] == "Withings")
        let second = try #require(rows[day("2026-11-10")])
        #expect(second.weightKg == 82.9)
        #expect(second.bodyFatPct == 18.6) // no Withings body fat → earliest of the day
        #expect(second.sources[.bodyFat] == "Health")
    }

    @Test func `body fat without any weight uses the earliest sample`() {
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-09"), samples: [
            .bodyFatPercentage: [quantity(19, at: "2026-11-09 09:00", withings), quantity(18, at: "2026-11-09 07:00", withings)],
        ])
        let row = aggregate(batch)[day("2026-11-09")]
        #expect(row?.weightKg == nil)
        #expect(row?.bodyFatPct == 18)
    }

    @Test func `samples use local day boundaries of the given time zone`() {
        // 00:30 on 2026-11-10 in Zagreb is 23:30 UTC on 2026-11-09.
        let sample = quantity(81.0, at: "2026-11-10 00:30", withings)
        let days = day("2026-11-09") ... day("2026-11-10")
        let batch = HealthDataBatch(days: days, samples: [.bodyMass: [sample]])
        #expect(aggregate(batch, calendar: zagreb)[day("2026-11-10")]?.weightKg == 81.0)
        #expect(aggregate(batch, calendar: zagreb)[day("2026-11-09")]?.weightKg == nil)
        #expect(aggregate(batch, calendar: HealthFixtures.utc)[day("2026-11-09")]?.weightKg == 81.0)
    }

    @Test func `resting heart rate prefers the watch and takes the latest`() {
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-10"), samples: [
            .restingHeartRate: [
                quantity(60, at: "2026-11-09 22:00", HealthFixtures.healthApp),
                quantity(55, at: "2026-11-09 08:00", watch),
                quantity(52, at: "2026-11-09 20:00", watch),
                quantity(58, at: "2026-11-10 10:00", HealthFixtures.healthApp),
            ],
        ])
        let rows = aggregate(batch)
        #expect(rows[day("2026-11-09")]?.restingHR == 52)
        #expect(rows[day("2026-11-09")]?.sources[.restingHeartRate] == watch.name)
        #expect(rows[day("2026-11-10")]?.restingHR == 58) // no watch that day → the other source
    }

    @Test func `overnight HRV averages 00 00 to 09 00, DST day included`() throws {
        // 2026-03-29: the 00:00–09:00 window holds only 8 h of real time.
        let batch = HealthDataBatch(days: day("2026-03-29") ... day("2026-03-30"), samples: [
            .heartRateVariabilitySDNN: [
                quantity(100, at: "2026-03-28 23:30", watch), // previous evening
                quantity(40, at: "2026-03-29 01:00", watch),
                quantity(60, at: "2026-03-29 08:30", watch),
                quantity(200, at: "2026-03-29 02:00", HealthFixtures.sleepApp), // another app while the watch has data
                quantity(90, at: "2026-03-29 09:00", watch), // window end is exclusive
                quantity(70, at: "2026-03-30 12:00", watch), // daytime only
            ],
        ])
        let rows = aggregate(batch)
        let spring = try #require(rows[day("2026-03-29")])
        #expect(spring.hrvSDNNms == 50)
        #expect(spring.sources[.hrv] == watch.name)
        #expect(rows[day("2026-03-30")]?.hrvSDNNms == nil)
    }

    @Test func `sleep columns come from the sleep aggregator`() throws {
        let phoneOnly = sleep(.inBed, "2026-11-09 23:00", "2026-11-10 07:00", HealthFixtures.iPhone)
        let batch = HealthDataBatch(days: day("2026-11-09") ... day("2026-11-10"), sleep: watchNight() + [phoneOnly])
        let rows = aggregate(batch)
        let watchRow = try #require(rows[day("2026-11-09")])
        #expect(watchRow.sleepAsleepMin == 465)
        #expect(watchRow.sleepInBedMin == 480)
        #expect(watchRow.sleepCoreMin == 330)
        #expect(watchRow.sleepDeepMin == 60)
        #expect(watchRow.sleepRemMin == 75)
        #expect(watchRow.sleepAwakeMin == 15)
        #expect(watchRow.sources[.sleep] == watch.name)

        let phoneRow = try #require(rows[day("2026-11-10")])
        #expect(phoneRow.sleepInBedMin == 480)
        #expect(phoneRow.sleepAsleepMin == nil)
        #expect(phoneRow.sleepCoreMin == nil)
        #expect(phoneRow.sleepAwakeMin == nil)
        #expect(phoneRow.hasValue(.sleep))
        #expect(phoneRow.sources[.sleep] == "jaPhone")
    }

    @Test func `has value and is empty`() {
        var metrics = DailyHealthMetrics(day: day("2026-11-09"))
        #expect(metrics.isEmpty)
        for metric in HealthMetric.allCases {
            #expect(!metrics.hasValue(metric))
        }
        metrics.waterMl = 250
        #expect(!metrics.isEmpty)
        #expect(metrics.hasValue(.water))
        let full = DailyHealthMetrics(
            day: day("2026-11-09"), steps: 1, activeKcal: 1, basalKcal: 1, sleepAsleepMin: 1, sleepInBedMin: 1,
            sleepCoreMin: 1, sleepDeepMin: 1, sleepRemMin: 1, sleepAwakeMin: 0, weightKg: 1, bodyFatPct: 1,
            restingHR: 1, hrvSDNNms: 1, waterMl: 1,
        )
        #expect(HealthMetric.allCases.allSatisfy { full.hasValue($0) })
    }

    @Test func `source summary JSON`() {
        var metrics = DailyHealthMetrics(day: day("2026-11-09"))
        metrics.sources = [.weight: "Withings", .steps: "Ivan's Apple Watch", .bodyFat: "Withings"]
        let json = metrics.sourceSummaryJSON
        #expect(json == #"{"body_fat":"Withings","steps":"Ivan's Apple Watch","weight":"Withings"}"#)
        #expect(DailyHealthMetrics.sources(fromJSON: json) == metrics.sources)
        // Unknown keys (newer app versions) and junk are ignored.
        #expect(DailyHealthMetrics.sources(fromJSON: #"{"steps":"Watch","vo2max":"Watch"}"#) == [.steps: "Watch"])
        #expect(DailyHealthMetrics.sources(fromJSON: "not json").isEmpty)
        #expect(DailyHealthMetrics.sources(fromJSON: nil).isEmpty)
    }

    @Test func `metric units are documented`() {
        #expect(CumulativeMetric.allCases.map(\.unitSymbol) == ["count", "kcal", "kcal", "ml"])
        #expect(SampledMetric.allCases.map(\.unitSymbol) == ["kg", "%", "count/min", "ms"])
        #expect(HealthMetric.allCases.map(\.rawValue) == [
            "steps", "active_kcal", "basal_kcal", "sleep", "weight", "body_fat", "resting_hr", "hrv", "water",
        ])
    }
}
