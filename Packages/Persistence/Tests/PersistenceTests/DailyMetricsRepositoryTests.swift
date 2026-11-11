import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct DailyMetricsRepositoryTests {
    func sample(_ dayString: String, steps: Int? = 8000, weight: Double? = 82.4) -> DailyHealthMetrics {
        var sources: [HealthMetric: String] = [:]
        if steps != nil {
            sources[.steps] = "Ivan's Apple Watch"
        }
        if weight != nil {
            sources[.weight] = "Withings"
        }
        return DailyHealthMetrics(
            day: day(dayString), steps: steps, activeKcal: 512.5, basalKcal: 1690,
            sleepAsleepMin: 465, sleepInBedMin: 480, sleepCoreMin: 330, sleepDeepMin: 60, sleepRemMin: 75, sleepAwakeMin: 15,
            weightKg: weight, bodyFatPct: 18.2, restingHR: 52, hrvSDNNms: 48.5, waterMl: 1750, sources: sources,
        )
    }

    @Test func `insert and read back every column`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        let metrics = sample("2026-11-09")
        #expect(try repo.upsert([metrics]) == 1)

        let row = try #require(try repo.metrics(on: day("2026-11-09")))
        #expect(row.metrics == metrics)
        #expect(row.sourceSummary == #"{"steps":"Ivan's Apple Watch","weight":"Withings"}"#)
        #expect(row.fetchedAt == f.clock.now)
        #expect(row.updatedAt == f.clock.now)
        #expect(row.revision == 1)
        #expect(row.weightTrendKg == nil)
        #expect(try repo.metrics(on: day("2026-11-08")) == nil)
    }

    @Test func `unchanged refresh only touches fetched at`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        try repo.upsert([sample("2026-11-09")])
        let created = f.clock.now
        f.clock.advance(3600)

        #expect(try repo.upsert([sample("2026-11-09")]) == 0)
        let row = try #require(try repo.metrics(on: day("2026-11-09")))
        #expect(row.revision == 1)
        #expect(row.updatedAt == created)
        #expect(row.fetchedAt == f.clock.now)
    }

    @Test func `changed values bump revision and keep the weight trend`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        try repo.upsert([sample("2026-11-09")])
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE daily_metrics SET weight_trend_kg = 82.1 WHERE day = '2026-11-09'")
        }
        f.clock.advance(60)

        #expect(try repo.upsert([sample("2026-11-09", steps: 9500)]) == 1)
        let row = try #require(try repo.metrics(on: day("2026-11-09")))
        #expect(row.steps == 9500)
        #expect(row.revision == 2)
        #expect(row.updatedAt == f.clock.now)
        #expect(row.weightTrendKg == 82.1)

        // Data deleted in Health disappears from the cache too.
        f.clock.advance(60)
        #expect(try repo.upsert([DailyHealthMetrics(day: day("2026-11-09"))]) == 1)
        let emptied = try #require(try repo.metrics(on: day("2026-11-09")))
        #expect(emptied.metrics.isEmpty)
        #expect(emptied.sourceSummary == nil)
        #expect(emptied.revision == 3)
    }

    @Test func `range reads are ordered and bounded`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        let rows = ["2026-11-10", "2026-11-07", "2026-11-08", "2026-11-12"].map { sample($0) }
        #expect(try repo.upsert(rows) == 4)
        let range = try repo.metrics(in: day("2026-11-08") ... day("2026-11-10"))
        #expect(range.map(\.day.isoString) == ["2026-11-08", "2026-11-10"])
    }

    @Test func `metrics with data`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        let days = day("2026-11-01") ... day("2026-11-09")
        #expect(try repo.metricsWithData(in: days).isEmpty)
        try repo.upsert([DailyHealthMetrics(day: day("2026-11-02")), DailyHealthMetrics(day: day("2026-11-03"), waterMl: 250)])
        #expect(try repo.metricsWithData(in: days) == [.water])
        try repo.upsert([sample("2026-11-05", steps: nil, weight: nil)])
        let found = try repo.metricsWithData(in: days)
        #expect(!found.contains(.steps))
        #expect(!found.contains(.weight))
        #expect(found.contains(.sleep))
        #expect(found.contains(.hrv))
    }

    @Test func `last fetched at and delete all`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        #expect(try repo.lastFetchedAt() == nil)
        try repo.upsert([sample("2026-11-08")])
        f.clock.advance(120)
        try repo.upsert([sample("2026-11-09")])
        #expect(try repo.lastFetchedAt() == f.clock.now)
        try repo.deleteAll()
        #expect(try repo.metrics(in: day("2026-11-01") ... day("2026-11-30")).isEmpty)
    }

    @Test func `observation delivers updates`() async throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        var iterator = repo.observeMetrics(on: day("2026-11-09")).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == .some(nil))
        try repo.upsert([sample("2026-11-09")])
        let updated = try await iterator.next()
        #expect(updated??.steps == 8000)

        var rangeIterator = repo.observeMetrics(in: day("2026-11-01") ... day("2026-11-30")).makeAsyncIterator()
        #expect(try await rangeIterator.next()?.count == 1)
    }

    @Test func `daily metrics survive export and import`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        try repo.upsert([sample("2026-11-09")])
        let exported = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()

        let other = try AppDatabase.inMemory()
        try DataPortability(other, clock: f.clock.appClock).importJSON(exported, mode: .replace)
        let restored = try DailyMetricsRepository(other).metrics(on: day("2026-11-09"))
        #expect(restored?.metrics == sample("2026-11-09"))
    }

    @Test func `woke at round trips`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        var night = sample("2026-11-09")
        night.wokeAt = Date(timeIntervalSince1970: 1_794_288_600) // 2026-11-10 06:50 UTC
        #expect(try repo.upsert([night]) == 1)
        #expect(try repo.metrics(on: night.day)?.wokeAt == night.wokeAt)
        #expect(try repo.metrics(on: night.day)?.metrics == night)
        #expect(try repo.upsert([night]) == 0)

        var earlier = night
        earlier.wokeAt = night.wokeAt?.addingTimeInterval(-1800)
        #expect(try repo.upsert([earlier]) == 1)
        #expect(try repo.metrics(on: night.day)?.wokeAt == earlier.wokeAt)
    }

    @Test func `weight trend on or before`() throws {
        let f = try Fixture()
        let repo = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        let first = day("2026-11-03")
        try repo.upsert([sample("2026-11-02"), sample("2026-11-03"), sample("2026-11-04"), sample("2026-11-05")])
        try repo.setWeightTrends([first: 80, first.adding(days: 2): 81]) // 11-04 and 11-02 have no trend

        #expect(try repo.weightTrendKg(onOrBefore: day("2026-11-02")) == nil)
        #expect(try repo.weightTrendKg(onOrBefore: first) == 80)
        #expect(try repo.weightTrendKg(onOrBefore: day("2026-11-04")) == 80)
        #expect(try repo.weightTrendKg(onOrBefore: day("2026-11-05")) == 81)
        #expect(try repo.weightTrendKg(onOrBefore: day("2026-12-01")) == 81)

        let trends = try repo.weightTrends(in: day("2026-11-01") ... day("2026-11-07"))
        #expect(trends == [
            day("2026-11-03"): 80, day("2026-11-04"): 80, day("2026-11-05"): 81, day("2026-11-06"): 81, day("2026-11-07"): 81,
        ])
        // A range after the last trend still carries it; one before any trend is empty.
        #expect(try repo.weightTrends(in: day("2026-11-20") ... day("2026-11-21")) == [day("2026-11-20"): 81, day("2026-11-21"): 81])
        #expect(try repo.weightTrends(in: day("2026-10-01") ... day("2026-11-02")).isEmpty)
    }
}
