import Foundation
import Testing
@testable import Core

struct BarcodeResolutionStatsTests {
    let now = Date(timeIntervalSince1970: 1_794_200_000)
    let hour: TimeInterval = 3600

    func event(_ barcode: String, _ outcome: ScanOutcome, hoursAgo: Double, quality: String? = nil) -> ScanEvent {
        ScanEvent(date: now.addingTimeInterval(-hoursAgo * hour), barcode: barcode, outcome: outcome, dataQuality: quality)
    }

    @Test func `empty log has no rates`() {
        let stats = BarcodeResolutionStats(events: [], now: now)
        #expect(stats.scanRate == nil)
        #expect(stats.rawScanRate == nil)
        #expect(stats.barcodeRate == nil)
        #expect(stats.regularRate == nil)
        #expect(stats.meetsTarget == nil)
        #expect(stats.count(.local) == 0)
    }

    @Test func `local and OFF answers count as resolved, offline is left out`() {
        let events = [
            event("A", .local, hoursAgo: 1),
            event("B", .offNetwork, hoursAgo: 2, quality: "complete"),
            event("C", .offCache, hoursAgo: 3, quality: "partial_macros"),
            event("D", .offStaleCache, hoursAgo: 4, quality: "complete"),
            event("E", .notFound, hoursAgo: 5),
            event("F", .offline, hoursAgo: 6),
            event("G", .unavailable, hoursAgo: 7),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.resolvedScans == 4)
        #expect(stats.conclusiveScans == 5)
        #expect(stats.scanRate == 0.8)
        #expect(stats.rawScanRate == 0.8)
        #expect(stats.distinctBarcodes == 5)
        #expect(stats.barcodeRate == 0.8)
        #expect(stats.count(.offline) == 1)
        #expect(stats.count(.unavailable) == 1)
        #expect(stats.offQualityCounts == ["complete": 2, "partial_macros": 1])
    }

    @Test func `a miss followed by a manual entry is excused and later scans resolve`() {
        let events = [
            event("X", .notFound, hoursAgo: 48),
            event("X", .created, hoursAgo: 47.9),
            event("X", .local, hoursAgo: 24),
            event("X", .local, hoursAgo: 1),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.excusedMisses == 1)
        #expect(stats.scanRate == 1)
        let twoThirds = 2.0 / 3.0
        #expect(stats.rawScanRate == twoThirds)
        #expect(stats.barcodeRate == 1)
        #expect(stats.regularBarcodes == 1)
        #expect(stats.regularRate == 1)
        #expect(stats.meetsTarget == true)
        #expect(stats.count(.created) == 1)
    }

    @Test func `a food made outside the scan flow after the miss excuses it`() {
        let events = [
            event("X", .notFound, hoursAgo: 48),
            event("X", .local, hoursAgo: 1),
            event("Y", .notFound, hoursAgo: 10), // known before the miss: e.g. a food restored with an old link
        ]
        let known = [
            "X": now.addingTimeInterval(-40 * hour), // created in the Foods tab, no `created` event
            "Y": now.addingTimeInterval(-20 * hour),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now, knownSince: known)
        #expect(stats.excusedMisses == 1)
        #expect(stats.scanRate == 0.5)
        #expect(stats.resolvedBarcodes == 1)
    }

    @Test func `a miss after the manual entry still counts`() {
        let events = [
            event("X", .created, hoursAgo: 48),
            event("X", .notFound, hoursAgo: 24), // e.g. the food was deleted
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.excusedMisses == 0)
        #expect(stats.scanRate == 0)
        #expect(stats.barcodeRate == 0)
    }

    @Test func `a miss without a manual entry counts every time`() {
        let events = [
            event("Y", .notFound, hoursAgo: 30),
            event("Y", .notFound, hoursAgo: 20),
            event("Z", .local, hoursAgo: 10),
            event("Z", .local, hoursAgo: 5),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.scanRate == 0.5)
        #expect(stats.barcodeRate == 0.5)
        #expect(stats.regularBarcodes == 2)
        #expect(stats.regularRate == 0.5)
        #expect(stats.meetsTarget == false)
    }

    @Test func `distinct barcodes are judged by their latest scan`() {
        let events = [
            event("P", .notFound, hoursAgo: 30),
            event("P", .offNetwork, hoursAgo: 10, quality: "complete"), // added to OFF meanwhile
            event("Q", .local, hoursAgo: 30),
            event("Q", .notFound, hoursAgo: 10),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.distinctBarcodes == 2)
        #expect(stats.resolvedBarcodes == 1)
    }

    @Test func `regular products need two conclusive scans`() {
        let events = [
            event("R", .local, hoursAgo: 30),
            event("R", .offline, hoursAgo: 20), // no answer: doesn't make R regular
            event("S", .notFound, hoursAgo: 10),
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.regularBarcodes == 0)
        #expect(stats.regularRate == nil)
        #expect(stats.scanRate == 0.5)
    }

    @Test func `events outside the window are ignored`() {
        let events = [
            event("A", .notFound, hoursAgo: 15 * 24),
            event("A", .local, hoursAgo: 13 * 24),
            event("B", .local, hoursAgo: -1), // in the future (clock change)
        ]
        let stats = BarcodeResolutionStats(events: events, now: now)
        #expect(stats.conclusiveScans == 1)
        #expect(stats.scanRate == 1)
        #expect(stats.count(.notFound) == 0)
        let week = BarcodeResolutionStats(events: events, now: now, days: 7)
        #expect(week.scanRate == nil)
    }

    @Test func `outcome raw values are stable`() {
        #expect(ScanOutcome.allCases.map(\.rawValue) == [
            "local", "off_network", "off_cache", "off_stale_cache", "not_found", "offline", "unavailable", "created",
        ])
        #expect(!ScanOutcome.created.isConclusiveScan)
        #expect(ScanOutcome.notFound.isConclusiveScan)
        #expect(!ScanOutcome.offline.isConclusiveScan)
    }
}
