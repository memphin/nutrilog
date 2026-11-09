import Core
import FoodLookup
import Foundation
import Persistence

extension AppEnvironment {
    /// The local barcode scan log (backlog #30); nil when the database could not be opened.
    var scanLog: ScanLogRepository? {
        db.map { ScanLogRepository($0, clock: clock) }
    }
}

/// Maps scan results to scan-log rows (backlog #30, SPEC §1.3). Logging is best effort: a failed write never
/// disturbs the scan.
enum ScanLogging {
    /// The outcome and data quality a lookup result is logged with.
    static func entry(
        for result: BarcodeLookupResult,
        candidates: [String],
    ) -> (barcode: String?, outcome: ScanOutcome, quality: DataQuality?) {
        switch result {
        case let .local(detail):
            // The scanned key the food was found under (a food can carry several codes).
            let keys = candidates.compactMap { Barcode.normalize($0) }
            return (keys.first(where: detail.barcodes.contains) ?? keys.first, .local, nil)
        case let .remote(product):
            let outcome: ScanOutcome = switch product.origin {
            case .network: .offNetwork
            case .cache: .offCache
            case .staleCache: .offStaleCache
            }
            return (product.barcode, outcome, product.quality)
        case let .notFound(barcode):
            return (barcode, .notFound, nil)
        }
    }

    /// The outcome a lookup error is logged with; nil for errors that aren't about coverage (invalid code, database).
    static func outcome(for error: any Error) -> ScanOutcome? {
        switch error {
        case BarcodeLookupError.offline: .offline
        case BarcodeLookupError.unavailable: .unavailable
        default: nil
        }
    }

    static func record(_ result: BarcodeLookupResult, candidates: [String], in log: ScanLogRepository?) {
        let entry = entry(for: result, candidates: candidates)
        guard let log, let barcode = entry.barcode else { return }
        try? log.record(barcode: barcode, outcome: entry.outcome, dataQuality: entry.quality)
    }

    static func record(_ error: any Error, candidates: [String], in log: ScanLogRepository?) {
        guard let log, let outcome = outcome(for: error), let barcode = primaryKey(candidates) else { return }
        try? log.record(barcode: barcode, outcome: outcome)
    }

    /// A food was created for a code the scan couldn't resolve: logs the one-time manual entry, but only when the new
    /// food carries the scanned code (the user may have typed another one).
    static func recordCreated(barcode: String?, saved: FoodDetail, in log: ScanLogRepository?) {
        guard let log, let barcode = barcode.flatMap({ Barcode.normalize($0) }), saved.barcodes.contains(barcode) else {
            return
        }
        try? log.record(barcode: barcode, outcome: .created)
    }

    /// The most likely normalized key among the scanner's candidates (what the lookup tries first).
    static func primaryKey(_ candidates: [String]) -> String? {
        candidates.lazy.compactMap { Barcode.normalize($0) }.first
    }
}
