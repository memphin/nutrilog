import Foundation

/// How one barcode scan ended, as kept in the local scan log (SPEC §1.3, backlog #30).
public enum ScanOutcome: String, CaseIterable, Hashable, Sendable {
    /// A local food carries the code.
    case local
    /// Open Food Facts answered just now.
    case offNetwork = "off_network"
    /// A fresh Open Food Facts answer from the product cache.
    case offCache = "off_cache"
    /// An expired cached Open Food Facts answer, served because OFF couldn't be reached.
    case offStaleCache = "off_stale_cache"
    /// Neither the local database nor Open Food Facts knows the code.
    case notFound = "not_found"
    /// No connection and nothing usable cached.
    case offline
    /// Open Food Facts didn't answer (timeout, rate limit, server error) and nothing usable cached.
    case unavailable
    /// Not a scan: the user created a food for a code the scan couldn't resolve (the one-time manual entry).
    case created

    /// A local food or an Open Food Facts answer (network, cache or stale cache).
    public var isResolved: Bool {
        switch self {
        case .local, .offNetwork, .offCache, .offStaleCache: true
        case .notFound, .offline, .unavailable, .created: false
        }
    }

    /// A scan whose answer says something about coverage: resolved, or definitely not found. Offline / unavailable
    /// scans never got an answer, and `created` is not a scan.
    public var isConclusiveScan: Bool {
        isResolved || self == .notFound
    }
}

/// One row of the scan log.
public struct ScanEvent: Hashable, Sendable {
    public var date: Date
    /// Normalized code (EAN-13 / EAN-8).
    public var barcode: String
    public var outcome: ScanOutcome
    /// Data quality of an Open Food Facts answer (`complete`, `partial_macros`, `energy_only`); nil otherwise.
    public var dataQuality: String?

    public init(date: Date, barcode: String, outcome: ScanOutcome, dataQuality: String? = nil) {
        self.date = date
        self.barcode = barcode
        self.outcome = outcome
        self.dataQuality = dataQuality
    }
}

/// The barcode resolution rate over a window of the scan log (SPEC §1.3: "≥ 90 % of scanned barcodes of regularly
/// purchased products resolve, after one-time manual entry for misses").
///
/// The computation:
/// - Only events inside the window (`now - days … now`) count.
/// - A scan is **resolved** when a local food or Open Food Facts (network, cache or stale cache) answered.
/// - **Offline / unavailable** scans got no answer and are left out of every rate (they are only counted).
/// - A **not-found** scan is **excused** when the barcode became known locally at or after the scan: that miss *is*
///   the one-time manual entry, so it leaves the denominator. "Known locally" comes from the data, not from how the
///   food was made: `knownSince` (an active food carries the code; from the database, so a food created in the Foods
///   tab, in Add Food or by an import counts too) or a `created` event logged by the scan flow. Later scans of the
///   code then hit the local food and count as resolved on their own. A miss that never led to a food counts.
/// - ``scanRate``: resolved ÷ (conclusive scans − excused misses). ``rawScanRate`` is the same without excusing.
/// - ``barcodeRate``: per distinct barcode, judged by its latest conclusive scan in the window (resolved or excused
///   → resolved), i.e. "does this product scan now".
/// - ``regularRate``: ``scanRate`` limited to barcodes with at least ``regularMinimumScans`` conclusive scans in the
///   window — the "regularly purchased products" of §1.3, and the number the target applies to.
public struct BarcodeResolutionStats: Hashable, Sendable {
    /// The target from SPEC §1.3.
    public static let target = 0.9
    public static let defaultDays = 14
    public static let regularMinimumScans = 2

    /// Events per outcome in the window (`created` included).
    public var counts: [ScanOutcome: Int]
    /// Open Food Facts answers in the window per data quality.
    public var offQualityCounts: [String: Int]
    public var resolvedScans: Int
    public var conclusiveScans: Int
    public var excusedMisses: Int
    public var distinctBarcodes: Int
    public var resolvedBarcodes: Int
    public var regularBarcodes: Int
    public var regularResolvedScans: Int
    public var regularCountedScans: Int

    /// Scans resolved, after excusing one-time manual entries; nil without any counted scan.
    public var scanRate: Double? {
        Self.rate(resolvedScans, conclusiveScans - excusedMisses)
    }

    /// Scans resolved without excusing anything; nil without any conclusive scan.
    public var rawScanRate: Double? {
        Self.rate(resolvedScans, conclusiveScans)
    }

    /// Distinct barcodes that resolve now; nil without any.
    public var barcodeRate: Double? {
        Self.rate(resolvedBarcodes, distinctBarcodes)
    }

    /// Scans of regularly bought products resolved (excusing one-time entries); nil without any regular product.
    public var regularRate: Double? {
        Self.rate(regularResolvedScans, regularCountedScans)
    }

    /// Whether the regular-product rate meets the §1.3 target; nil without data.
    public var meetsTarget: Bool? {
        regularRate.map { $0 >= Self.target }
    }

    public func count(_ outcome: ScanOutcome) -> Int {
        counts[outcome] ?? 0
    }

    static func rate(_ part: Int, _ whole: Int) -> Double? {
        whole > 0 ? Double(part) / Double(whole) : nil
    }

    /// Stats for the events in the last `days` days before `now` (events outside the window are ignored).
    ///
    /// `knownSince`: for barcodes an active local food carries now, when that became so (the later of the barcode
    /// link's and the food's last change).
    public init(events: [ScanEvent], now: Date, days: Int = defaultDays, knownSince: [String: Date] = [:]) {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let window = events.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }

        var counts: [ScanOutcome: Int] = [:]
        var quality: [String: Int] = [:]
        var knownAt = knownSince
        for event in window {
            counts[event.outcome, default: 0] += 1
            if event.outcome.isResolved, event.outcome != .local, let q = event.dataQuality {
                quality[q, default: 0] += 1
            }
            if event.outcome == .created {
                knownAt[event.barcode] = max(knownAt[event.barcode] ?? event.date, event.date)
            }
        }

        var tallies: [String: Tally] = [:]
        for event in window where event.outcome.isConclusiveScan {
            var tally = tallies[event.barcode] ?? Tally()
            tally.conclusive += 1
            if event.outcome.isResolved {
                tally.resolved += 1
                tally.counted += 1
                tally.latestOK = true
            } else if let known = knownAt[event.barcode], known >= event.date {
                tally.excused += 1
                tally.latestOK = true
            } else {
                tally.counted += 1
                tally.latestOK = false
            }
            tallies[event.barcode] = tally
        }

        let regular = tallies.values.filter { $0.conclusive >= Self.regularMinimumScans }
        self.counts = counts
        offQualityCounts = quality
        resolvedScans = tallies.values.reduce(0) { $0 + $1.resolved }
        conclusiveScans = tallies.values.reduce(0) { $0 + $1.conclusive }
        excusedMisses = tallies.values.reduce(0) { $0 + $1.excused }
        distinctBarcodes = tallies.count
        resolvedBarcodes = tallies.values.count(where: \.latestOK)
        regularBarcodes = regular.count
        regularResolvedScans = regular.reduce(0) { $0 + $1.resolved }
        regularCountedScans = regular.reduce(0) { $0 + $1.counted }
    }

    /// One barcode's conclusive scans in the window.
    private struct Tally {
        var resolved = 0
        /// Scans that count toward a rate: conclusive minus excused misses.
        var counted = 0
        var conclusive = 0
        var excused = 0
        /// The latest conclusive scan resolved, or was excused.
        var latestOK = false
    }
}
