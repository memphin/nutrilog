import Core
import FoodLookup
import FoodSources
import Foundation
import Observation
import Persistence
import SwiftUI

/// One online search hit (FR-20), names already title-cased: a USDA food with its nutrition, or an Open Food Facts
/// product whose nutrition is fetched by barcode when it is picked (Search-a-licious doesn't return nutrition).
struct OnlineFoodResult: Identifiable, Hashable {
    enum Content: Hashable {
        /// An unsaved food with its nutrition (USDA).
        case food(FoodDraft)
        /// An Open Food Facts product known only by barcode, names and brand.
        case offProduct(OFFSearchHit)
    }

    let content: Content

    init(_ draft: FoodDraft) {
        content = .food(draft.displayCased)
    }

    init(_ hit: OFFSearchHit) {
        content = .offProduct(hit.displayCased)
    }

    /// The food with its nutrition; `nil` for an Open Food Facts product until it is fetched.
    var draft: FoodDraft? {
        if case let .food(draft) = content {
            return draft
        }
        return nil
    }

    var origin: FoodDraft.Origin {
        switch content {
        case let .food(draft): draft.origin
        case .offProduct: .off
        }
    }

    var id: String {
        switch content {
        case let .food(draft): "\(draft.origin.rawValue):\(draft.sourceID)"
        case let .offProduct(hit): "\(FoodDraft.Origin.off.rawValue):\(hit.code)"
        }
    }

    var source: FoodSource {
        FoodSource(origin)
    }

    private var rawName: String? {
        switch content {
        case let .food(draft): draft.name
        case let .offProduct(hit): hit.name
        }
    }

    private var rawBrand: String? {
        switch content {
        case let .food(draft): draft.brand
        case let .offProduct(hit): hit.brand
        }
    }

    /// Name, else brand, else a generic label (OFF products sometimes have neither).
    var name: String {
        rawName ?? rawBrand ?? String(localized: "Unnamed product")
    }

    /// Brand shown under the name; `nil` when it already is the name.
    var brand: String? {
        rawName == nil ? nil : rawBrand
    }

    /// Product page for OFF hits ("View on Open Food Facts", ODbL attribution); `nil` for USDA.
    var offProductURL: URL? {
        switch content {
        case let .food(draft): draft.origin == .off ? draft.productURL : nil
        case let .offProduct(hit): hit.productURL
        }
    }

    /// Barcode compared across sources: normalized (UPC-A → EAN-13, …) when valid, else as given.
    var barcodeKey: String? {
        switch content {
        case let .food(draft): draft.barcode.map { Barcode.normalize($0) ?? $0 }
        case let .offProduct(hit): hit.code
        }
    }
}

/// State behind the "Online" segment of Add Food (backlog #22, FR-20): debounced, cancellable parallel searches of
/// Open Food Facts (packaged) and USDA FoodData Central (generic + branded), merged into one list as each source
/// answers. A source paused by a rate limit, or busy, is asked again by itself when the pause ends (a few times at
/// most per query).
///
/// Call ``search(_:offSearch:usda:nameLanguage:)`` from `.task(id:)` keyed on the query: SwiftUI cancels the previous call when
/// the text changes, which cancels its debounce wait or its in-flight requests, and a cancelled call never writes
/// its (stale) results.
@MainActor
@Observable
final class OnlineSearchModel {
    /// What one source is doing for the current query.
    enum SourceStatus: Equatable {
        /// No search yet (query too short).
        case idle
        /// USDA without an API key: the source is not shown at all.
        case hidden
        case loading
        case loaded(count: Int)
        case offline
        /// Rate-limit cool-down (USDA 429: 1 h, OFF 429: `Retry-After` or 60 s): no request until `until`, then
        /// the search runs again by itself.
        case paused(until: Date)
        /// OFF answered with a server error (503: overloaded); retried after ``busyRetryDelay``.
        case busy
        case failed(String)

        var isLoading: Bool {
            self == .loading
        }
    }

    /// Queries shorter than this (after trimming) don't go online.
    static let minimumQueryLength = 2
    /// How long to wait before asking a busy Open Food Facts again.
    static let busyRetryDelay: Duration = .seconds(5)
    /// Automatic retries of paused or busy sources per query, so a source that stays throttled isn't asked forever.
    static let maxAutomaticRetries = 3
    static let defaultDebounce: Duration = .milliseconds(400)
    /// Answers (per source and query) remembered while Add Food is open, so going back a character doesn't search
    /// again.
    static let cacheLimit = 60

    let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Tells VoiceOver when a source answers or fails (no-op otherwise).
    private let announce: @MainActor (String) -> Void

    /// The query the current results and statuses belong to (trimmed).
    private(set) var query = ""
    private(set) var offStatus: SourceStatus = .idle
    private(set) var usdaStatus: SourceStatus = .idle
    /// Merged results, in arrival order: each source's list is appended when it arrives. One row per product: a
    /// barcode (normalized) appears once, and OFF wins over USDA Branded — a USDA row is replaced in place when OFF
    /// arrives later with the same barcode.
    private(set) var results: [OnlineFoodResult] = []
    /// The Open Food Facts result whose product is being fetched after a tap; its row shows a spinner.
    private(set) var fetchingResultID: String?

    private var cache: [CacheKey: [OnlineFoodResult]] = [:]
    private var cacheOrder: [CacheKey] = []

    private struct CacheKey: Hashable {
        let origin: FoodDraft.Origin
        let query: String
    }

    private let now: @Sendable () -> Date

    init(
        debounce: Duration = OnlineSearchModel.defaultDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
    ) {
        self.debounce = debounce
        self.sleep = sleep
        self.now = now
        self.announce = announce
    }

    /// True while either visible source is still loading.
    var isLoading: Bool {
        offStatus.isLoading || usdaStatus.isLoading
    }

    /// "No online matches" only when a source actually answered: not while one is loading, and not when every
    /// visible source failed, is offline or is paused (their status rows already say so).
    var showsNoMatches: Bool {
        guard results.isEmpty, !isLoading else { return false }
        return [offStatus, usdaStatus].contains { status in
            if case .loaded = status {
                return true
            }
            return false
        }
    }

    /// Marks the sources as loading, waits ``debounce``, then queries both sources in parallel and publishes each
    /// one's results as they arrive. When cancelled (the query changed) it stops without publishing results.
    /// USDA is skipped — ``SourceStatus/hidden`` without a key, ``SourceStatus/paused(until:)`` during its
    /// rate-limit cool-down.
    /// `nameLanguage` is the food name language (Settings → Food names): Open Food Facts products with a Croatian
    /// name are named in Croatian when it is Croatian.
    func search(
        _ text: String, offSearch: any OpenFoodFactsSearchClient, usda: any USDAClient, nameLanguage: FoodNameLanguage,
    ) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else {
            reset(query: query, usda: usda)
            return
        }
        // Show the spinners at once; the previous results stay until the debounce has passed.
        offStatus = initialOFFStatus(offSearch)
        usdaStatus = initialUSDAStatus(usda)
        do {
            try await sleep(debounce)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        self.query = query
        results = []
        // A cool-down may have started while waiting.
        offStatus = initialOFFStatus(offSearch)
        usdaStatus = initialUSDAStatus(usda)

        var pending: [FoodDraft.Origin] = []
        for origin in [FoodDraft.Origin.off, .usda] where status(of: origin) != .hidden {
            if let cached = cache[CacheKey(origin: origin, query: query.lowercased())] {
                apply(origin, .success(cached)) // also during a cool-down: no request needed
            } else if status(of: origin) == .loading {
                pending.append(origin)
            }
        }
        await run(pending, query: query, offSearch: offSearch, usda: usda, nameLanguage: nameLanguage)

        // Paused or busy sources are asked again when the pause ends, while the query stays.
        for _ in 0 ..< Self.maxAutomaticRetries {
            guard let (origins, wait) = retryPlan() else { return }
            do {
                try await sleep(wait)
            } catch {
                return
            }
            guard !Task.isCancelled, self.query == query else { return }
            var retrying: [FoodDraft.Origin] = []
            for origin in origins {
                let status = origin == .off ? initialOFFStatus(offSearch) : initialUSDAStatus(usda)
                setStatus(status, for: origin)
                if status == .loading {
                    retrying.append(origin)
                }
            }
            await run(retrying, query: query, offSearch: offSearch, usda: usda, nameLanguage: nameLanguage)
        }
    }

    /// Queries `origins` in parallel and publishes each one's results as they arrive (unless a newer query took over).
    private func run(
        _ origins: [FoodDraft.Origin], query: String,
        offSearch: any OpenFoodFactsSearchClient, usda: any USDAClient, nameLanguage: FoodNameLanguage,
    ) async {
        guard !origins.isEmpty else { return }
        await withTaskGroup(of: (FoodDraft.Origin, Result<[OnlineFoodResult], any Error>).self) { group in
            for origin in origins {
                group.addTask {
                    do {
                        let found = switch origin {
                        case .off: try await offSearch.search(query: query, nameLanguage: nameLanguage)
                            .map(OnlineFoodResult.init)
                        case .usda: try await usda.search(query: query).map(OnlineFoodResult.init)
                        }
                        return (origin, .success(found))
                    } catch {
                        return (origin, .failure(error))
                    }
                }
            }
            for await (origin, outcome) in group {
                // A newer query took over: drop what this one found.
                guard !Task.isCancelled, self.query == query else { continue }
                if case let .success(found) = outcome {
                    remember(found, origin: origin, query: query.lowercased())
                }
                apply(origin, outcome, offPausedUntil: offSearch.rateLimitedUntil)
                announceStatus(of: origin)
            }
        }
    }

    /// The sources to ask again and how long to wait first: paused ones when their pause ends (only pauses still
    /// ahead), busy Open Food Facts after ``busyRetryDelay``. `nil` when no source needs it.
    private func retryPlan() -> (origins: [FoodDraft.Origin], wait: Duration)? {
        let now = now()
        var waits: [(FoodDraft.Origin, TimeInterval)] = []
        for origin in [FoodDraft.Origin.off, .usda] {
            switch status(of: origin) {
            case let .paused(until) where until > now:
                waits.append((origin, until.timeIntervalSince(now)))
            case .busy:
                waits.append((origin, Double(Self.busyRetryDelay.components.seconds)))
            default:
                break
            }
        }
        guard let longest = waits.map(\.1).max() else { return nil }
        // One wait for both, so a short busy retry doesn't run before a long pause ends twice over.
        return (waits.map(\.0), .milliseconds(Int((longest * 1000).rounded(.up)) + 100))
    }

    /// What to do after picking a result.
    enum Selection {
        /// Open the quantity sheet for this stored copy.
        case open(FoodDetail)
        /// The copy only has per-serving values without a weight: ask for it first.
        case askServingWeight(PendingServingWeight)
    }

    /// Why picking an Open Food Facts result failed; the message is shown in an alert.
    enum SelectionError: LocalizedError, Equatable {
        /// OFF no longer has the product.
        case productGone
        case offline
        /// OFF couldn't answer (rate limit, server error, timeout).
        case unavailable

        var errorDescription: String? {
            switch self {
            case .productGone: String(localized: "Open Food Facts no longer has this product.")
            case .offline: String(localized: "You're offline. Connect to load this product from Open Food Facts.")
            case .unavailable: String(localized: "Open Food Facts didn't answer. Try again in a moment.")
            }
        }
    }

    /// Saves a local copy of `result` so it can be logged, and later found by local search. Idempotent: picking the
    /// same result again returns the same food. An Open Food Facts result is fetched by barcode first (`lookup`:
    /// a food already saved with the code, the product cache, then OFF), with a spinner on its row meanwhile.
    ///
    /// Throws ``SelectionError``, `CancellationError`, or a database error.
    func select(_ result: OnlineFoodResult, in foods: FoodRepository, lookup: BarcodeLookup?) async throws -> Selection {
        switch result.content {
        case let .food(draft):
            return try Self.selection(for: foods.saveRemoteCopy(draft))
        case let .offProduct(hit):
            guard let lookup else { throw SelectionError.unavailable }
            fetchingResultID = result.id
            defer { fetchingResultID = nil }
            let resolved: BarcodeLookupResult
            do {
                resolved = try await lookup.resolve(hit.code)
            } catch BarcodeLookupError.offline {
                throw SelectionError.offline
            } catch is BarcodeLookupError {
                throw SelectionError.unavailable
            }
            switch resolved {
            case let .local(detail): return Self.selection(for: detail)
            case let .remote(product): return try Self.selection(for: foods.saveRemoteCopy(product.draft.displayCased))
            case .notFound: throw SelectionError.productGone
            }
        }
    }

    private static func selection(for detail: FoodDetail) -> Selection {
        detail.isPerServingPlaceholder ? .askServingWeight(PendingServingWeight(detail: detail)) : .open(detail)
    }

    // MARK: - Private

    private func status(of origin: FoodDraft.Origin) -> SourceStatus {
        origin == .off ? offStatus : usdaStatus
    }

    private func reset(query: String, usda: any USDAClient) {
        self.query = query
        results = []
        offStatus = .idle
        usdaStatus = usda.isAvailable ? .idle : .hidden
    }

    private func initialOFFStatus(_ offSearch: any OpenFoodFactsSearchClient) -> SourceStatus {
        offSearch.rateLimitedUntil.map { .paused(until: $0) } ?? .loading
    }

    private func initialUSDAStatus(_ usda: any USDAClient) -> SourceStatus {
        guard usda.isAvailable else { return .hidden }
        if let until = usda.rateLimitedUntil {
            return .paused(until: until)
        }
        return .loading
    }

    private func apply(
        _ origin: FoodDraft.Origin,
        _ outcome: Result<[OnlineFoodResult], any Error>,
        offPausedUntil: Date? = nil,
    ) {
        switch outcome {
        case let .success(found):
            merge(found)
            setStatus(.loaded(count: 0), for: origin)
            refreshCounts()
        case let .failure(error):
            if error is CancellationError {
                return
            }
            if origin == .off, case OpenFoodFactsError.rateLimited = error {
                setStatus(offPausedUntil.map { .paused(until: $0) } ?? .busy, for: origin)
            } else {
                setStatus(Self.status(for: error), for: origin)
            }
        }
    }

    /// Adds `found` to ``results``: skips ids and barcodes already listed (also within `found`), except that an OFF
    /// hit replaces a USDA row with the same barcode in place.
    private func merge(_ found: [OnlineFoodResult]) {
        var ids = Set(results.map(\.id))
        var indexByBarcode: [String: Int] = [:]
        for (index, result) in results.enumerated() {
            if let key = result.barcodeKey, indexByBarcode[key] == nil {
                indexByBarcode[key] = index
            }
        }
        for result in found where !ids.contains(result.id) {
            if let key = result.barcodeKey, let index = indexByBarcode[key] {
                if result.origin == .off, results[index].origin == .usda {
                    ids.remove(results[index].id)
                    results[index] = result
                    ids.insert(result.id)
                }
                continue
            }
            results.append(result)
            ids.insert(result.id)
            if let key = result.barcodeKey {
                indexByBarcode[key] = results.count - 1
            }
        }
    }

    /// Loaded counts follow ``results`` (a USDA row can be replaced by OFF later).
    private func refreshCounts() {
        for origin in [FoodDraft.Origin.off, .usda] {
            if case .loaded = status(of: origin) {
                setStatus(.loaded(count: results.count(where: { $0.origin == origin })), for: origin)
            }
        }
    }

    private func announceStatus(of origin: FoodDraft.Origin) {
        let status = status(of: origin)
        guard status != .loading, status != .hidden, status != .idle else { return }
        announce(OnlineSourceStatusRow.text(source: origin, status: status))
    }

    private func setStatus(_ status: SourceStatus, for origin: FoodDraft.Origin) {
        switch origin {
        case .off: offStatus = status
        case .usda: usdaStatus = status
        }
    }

    private func remember(_ found: [OnlineFoodResult], origin: FoodDraft.Origin, query: String) {
        let key = CacheKey(origin: origin, query: query)
        if cache.updateValue(found, forKey: key) == nil {
            cacheOrder.append(key)
        }
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    static func status(for error: any Error) -> SourceStatus {
        switch error {
        case let error as OpenFoodFactsError:
            switch error {
            case .offline: .offline
            case .rateLimited, .server: .busy
            case .timedOut: .failed(String(localized: "Open Food Facts didn't answer in time."))
            default: .failed(String(localized: "Open Food Facts search failed."))
            }
        case let error as USDAError:
            switch error {
            case .missingAPIKey: .hidden
            case let .rateLimited(until): .paused(until: until)
            case .offline: .offline
            case .invalidAPIKey: .failed(String(localized: "USDA rejected the API key, so USDA search is unavailable."))
            case .timedOut: .failed(String(localized: "USDA didn't answer in time."))
            default: .failed(String(localized: "USDA search failed."))
            }
        default:
            .failed(String(localized: "Search failed."))
        }
    }
}

/// `.task(id:)` key for the online search: a new query, or switching to or from the Online segment, restarts it.
struct OnlineSearchKey: Equatable {
    let query: String
    let isOnline: Bool
}
