import Core
import Foundation
import Testing
@testable import Persistence

struct LocalHealthSampleIDsTests {
    @Test func `every weight and water row counts, soft-deleted too, plus linked and queued ones`() throws {
        let f = try Fixture()
        let weights = WeightRepository(f.db, clock: f.clock.appClock)
        let metrics = DailyMetricsRepository(f.db, clock: f.clock.appClock)
        #expect(try metrics.localHealthSampleIDs().isEmpty)

        let weight = try weights.add(kg: 80, bodyFatPct: 20)
        let deletedWeight = try weights.add(kg: 81)
        try weights.softDelete(ids: [deletedWeight.id])
        let water = try f.water.add(ml: 250, day: day("2026-11-09"))
        let deletedWater = try f.water.add(ml: 300, day: day("2026-11-09"))
        try f.water.softDelete(ids: [deletedWater.id])
        let bread = try f.makeFood("Bread")
        let diary = try f.diary.log(food: bread, quantity: .base(50), slotID: "breakfast", day: day("2026-11-09"))
        // Rows a replace import removed: still linked / queued until the outbox deletes their samples.
        try f.healthLinks.replaceLinks(for: .weightEntry, id: "imported-away", with: [("HKQuantityTypeIdentifierBodyMass", "u1")])
        try f.healthLinks.enqueue(.waterEntry, id: "queued-away")
        try f.healthLinks.replaceLinks(for: .diaryEntry, id: "diary-away", with: [("HKQuantityTypeIdentifierDietaryProtein", "u2")])

        let ids = try metrics.localHealthSampleIDs()
        #expect(ids == [weight.id, deletedWeight.id, water.id, deletedWater.id, "imported-away", "queued-away"])
        #expect(!ids.contains(diary.id))
    }
}

struct HealthKitOutboxSummaryTests {
    @Test func `summary counts queued and failed rows without loading them`() throws {
        let f = try Fixture()
        #expect(try f.healthLinks.pendingSummary() == HealthKitOutboxSummary())
        try f.healthLinks.enqueue(.diaryEntry, id: "a")
        try f.healthLinks.enqueue(.waterEntry, id: "b")
        try f.healthLinks.enqueue(.weightEntry, id: "c")
        let items = try f.healthLinks.pending()
        try f.healthLinks.recordFailure(items[0], error: "first")
        try f.healthLinks.recordFailure(items[2], error: "newest")
        let summary = try f.healthLinks.pendingSummary()
        #expect(summary == HealthKitOutboxSummary(queuedCount: 3, failedCount: 2, lastError: "newest"))
        // Same numbers as counting the loaded rows.
        let failed = try f.healthLinks.pending().filter { $0.lastError != nil }
        #expect(summary.failedCount == failed.count && summary.lastError == failed.last?.lastError)
    }
}
