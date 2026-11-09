import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct ScanLogRepositoryTests {
    func log(_ f: Fixture) -> ScanLogRepository {
        ScanLogRepository(f.db, clock: f.clock.appClock)
    }

    @Test func `scan log is migrated (006) and not exported`() throws {
        let f = try Fixture()
        #expect(Migrator.migrations.contains("006_barcode_scan_log"))
        try log(f).record(barcode: "4006381333931", outcome: .local)
        let data = try DataPortability(f.db, clock: f.clock.appClock).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tables = try #require(object["tables"] as? [String: Any])
        #expect(tables["barcode_scan_log"] == nil)
        #expect(!DataPortability.tables.contains("barcode_scan_log"))
    }

    @Test func `records events with outcome and quality, oldest first`() throws {
        let f = try Fixture()
        let repo = log(f)
        let start = f.clock.now
        try repo.record(barcode: "3017620422003", outcome: .offNetwork, dataQuality: .partialMacros)
        f.clock.advance(60)
        try repo.record(barcode: "5901234123457", outcome: .notFound)
        f.clock.advance(60)
        try repo.record(barcode: "5901234123457", outcome: .created)

        let events = try repo.events(since: start)
        #expect(events.map(\.outcome) == [.offNetwork, .notFound, .created])
        #expect(events[0].dataQuality == "partial_macros")
        #expect(events[0].date == start)
        #expect(events[1].dataQuality == nil)

        let stats = try repo.stats()
        #expect(stats.excusedMisses == 1)
        #expect(stats.scanRate == 1)
        #expect(stats.count(.created) == 1)
    }

    @Test func `the database rejects unknown outcomes`() throws {
        let f = try Fixture()
        #expect(throws: DatabaseError.self) {
            try f.db.writer.write { db in
                try db.execute(sql: """
                INSERT INTO barcode_scan_log (scanned_at, barcode, outcome) VALUES ('x', '1', 'bogus')
                """)
            }
        }
    }

    @Test func `old rows are pruned and clear empties the log`() throws {
        let f = try Fixture()
        let repo = log(f)
        try repo.record(barcode: "1", outcome: .local)
        f.clock.advance(ScanLogRepository.retention + 1)
        try repo.record(barcode: "2", outcome: .local)
        #expect(try repo.count() == 1)
        #expect(try repo.stats().conclusiveScans == 1)

        try repo.clear()
        #expect(try repo.count() == 0)
        #expect(try repo.stats().scanRate == nil)
    }

    @Test func `stats only see the window`() throws {
        let f = try Fixture()
        let repo = log(f)
        try repo.record(barcode: "1", outcome: .notFound)
        f.clock.advance(15 * 86400)
        try repo.record(barcode: "2", outcome: .local)
        let stats = try repo.stats()
        #expect(stats.conclusiveScans == 1)
        #expect(stats.scanRate == 1)
    }
}
