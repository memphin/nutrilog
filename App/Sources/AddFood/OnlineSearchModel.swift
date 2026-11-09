import Core
import FoodLookup
import FoodSources
import Foundation
import Observation
import Persistence

/// One online search hit (FR-20): an unsaved food from Open Food Facts or USDA, with names already title-cased.
struct OnlineFoodResult: Identifiable, Hashable {
    let draft: FoodDraft

    init(_ draft: FoodDraft) {
        self.draft = draft.displayCased
    }

    var id: String {
        "\(draft.origin.rawValue):\(draft.sourceID)"
    }

    var source: FoodSource {
        FoodSource(draft.origin)
    }

    /// Name, else brand, else a generic label (OFF products sometimes have neither).
    var name: String {
        draft.name ?? draft.brand ?? "Unnamed product"
    }

    /// Brand shown under the name; `nil` when it already is the name.
    var brand: String? {
        draft.name == nil ? nil : draft.brand
    }
}

/// State behind the "Online" segment of Add Food (backlog #22, FR-20): debounced, cancellable parallel searches of
/// Open Food Facts (packaged) and USDA FoodData Central (generic + branded), merged into one list as each source
/// answers.
///
/// Call ``search(_:offSearch:usda:)`` from `.task(id:)` keyed on the query: SwiftUI cancels the previous call when
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
        /// USDA HTTP 429 cool-down: no request until `until`.
        case paused(until: Date)
        /// OFF throttled the search (HTTP 429/503).
        case busy
        case failed(String)

        var isLoading: Bool {
            self == .loading
        }
    }

    /// Queries shorter than this (after trimming) don't go online: OFF allows ~10 searches a minute.
    static let minimumQueryLength = 2
    static let defaultDebounce: Duration = .milliseconds(400)
    /// Answers (per source and query) remembered while Add Food is open, so going back a character doesn't search
    /// again.
    static let cacheLimit = 60

    let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// The query the current results and statuses belong to (trimmed).
    private(set) var query = ""
    private(set) var offStatus: SourceStatus = .idle
    private(set) var usdaStatus: SourceStatus = .idle
    /// Merged results, in arrival order: each source's list is appended when it arrives, so rows already on
    /// screen never move. A USDA Branded hit whose barcode an OFF hit already has (or vice versa) is left out.
    private(set) var results: [OnlineFoodResult] = []

    private var cache: [CacheKey: [OnlineFoodResult]] = [:]
    private var cacheOrder: [CacheKey] = []

    private struct CacheKey: Hashable {
        let origin: FoodDraft.Origin
        let query: String
    }

    init(
        debounce: Duration = OnlineSearchModel.defaultDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        self.debounce = debounce
        self.sleep = sleep
    }

    /// True while either visible source is still loading.
    var isLoading: Bool {
        offStatus.isLoading || usdaStatus.isLoading
    }

    /// Marks the sources as loading, waits ``debounce``, then queries both sources in parallel and publishes each
    /// one's results as they arrive. When cancelled (the query changed) it stops without publishing results.
    /// USDA is skipped — ``SourceStatus/hidden`` without a key, ``SourceStatus/paused(until:)`` during its
    /// rate-limit cool-down.
    func search(_ text: String, offSearch: any OpenFoodFactsSearchClient, usda: any USDAClient) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength else {
            reset(query: query, usda: usda)
            return
        }
        // Show the spinners at once; the previous results stay until the debounce has passed.
        offStatus = .loading
        usdaStatus = initialUSDAStatus(usda)
        do {
            try await sleep(debounce)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        self.query = query
        results = []
        // The cool-down may have started while waiting.
        usdaStatus = initialUSDAStatus(usda)

        var pending: [FoodDraft.Origin] = []
        for origin in [FoodDraft.Origin.off, .usda] where status(of: origin) == .loading {
            if let cached = cache[CacheKey(origin: origin, query: query.lowercased())] {
                apply(origin, .success(cached))
            } else {
                pending.append(origin)
            }
        }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: (FoodDraft.Origin, Result<[OnlineFoodResult], any Error>).self) { group in
            for origin in pending {
                group.addTask {
                    do {
                        let drafts = switch origin {
                        case .off: try await offSearch.search(query: query)
                        case .usda: try await usda.search(query: query)
                        }
                        return (origin, .success(drafts.map(OnlineFoodResult.init)))
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
                apply(origin, outcome)
            }
        }
    }

    /// What to do after picking a result.
    enum Selection {
        /// Open the quantity sheet for this stored copy.
        case open(FoodDetail)
        /// The copy only has per-serving values without a weight: ask for it first.
        case askServingWeight(PendingServingWeight)
    }

    /// Saves a local copy of `result` (source off/usda) so it can be logged, and later found by local search.
    /// Idempotent: picking the same result again returns the same food.
    func select(_ result: OnlineFoodResult, in foods: FoodRepository) throws -> Selection {
        let detail = try foods.saveRemoteCopy(result.draft)
        guard detail.isPerServingPlaceholder else { return .open(detail) }
        let quality = FoodDraft.classify(basis: .per100, missing: result.draft.missingNutrients)
        return .askServingWeight(PendingServingWeight(detail: detail, qualityWithWeight: DataQuality(quality)))
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

    private func initialUSDAStatus(_ usda: any USDAClient) -> SourceStatus {
        guard usda.isAvailable else { return .hidden }
        if let until = usda.rateLimitedUntil {
            return .paused(until: until)
        }
        return .loading
    }

    private func apply(_ origin: FoodDraft.Origin, _ outcome: Result<[OnlineFoodResult], any Error>) {
        switch outcome {
        case let .success(found):
            let known = Set(results.compactMap(\.draft.barcode))
            let ids = Set(results.map(\.id))
            let added = found.filter { result in
                !ids.contains(result.id) && !(result.draft.barcode.map(known.contains) ?? false)
            }
            results += added
            setStatus(.loaded(count: added.count), for: origin)
        case let .failure(error):
            if error is CancellationError {
                return
            }
            setStatus(Self.status(for: error), for: origin)
        }
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
            case .timedOut: .failed("Open Food Facts didn't answer in time.")
            default: .failed("Open Food Facts search failed.")
            }
        case let error as USDAError:
            switch error {
            case .missingAPIKey: .hidden
            case let .rateLimited(until): .paused(until: until)
            case .offline: .offline
            case .invalidAPIKey: .failed("USDA rejected the API key. Check it in Settings → Food sources.")
            case .timedOut: .failed("USDA didn't answer in time.")
            default: .failed("USDA search failed.")
            }
        default:
            .failed("Search failed.")
        }
    }
}

/// `.task(id:)` key for the online search: a new query, or switching to or from the Online segment, restarts it.
struct OnlineSearchKey: Equatable {
    let query: String
    let isOnline: Bool
}
