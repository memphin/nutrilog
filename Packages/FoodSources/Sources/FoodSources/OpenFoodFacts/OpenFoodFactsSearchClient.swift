import Core
import Foundation
import Synchronization

/// One Open Food Facts search hit (SPEC §3.1, FR-20): enough to list the product, not its nutrition. Search-a-licious
/// doesn't index nutriments, so the product is fetched by barcode (``OpenFoodFactsClient``) once the user picks it.
public struct OFFSearchHit: Hashable, Sendable {
    /// The barcode, normalized (`Core.Barcode`): the key the product lookup and the saved copy use.
    public var code: String
    /// Name in the food name language (see ``OFFFoodMapper/names(_:language:)``); `nil` when OFF has none.
    public var name: String?
    /// The other-language name when it differs.
    public var nameLocal: String?
    /// First brand.
    public var brand: String?
    /// Package size as printed, e.g. "220g".
    public var quantity: String?

    public init(code: String, name: String? = nil, nameLocal: String? = nil, brand: String? = nil, quantity: String? = nil) {
        self.code = code
        self.name = name
        self.nameLocal = nameLocal
        self.brand = brand
        self.quantity = quantity
    }

    /// The product page ("View on Open Food Facts", ODbL attribution).
    public var productURL: URL? {
        URL(string: "https://world.openfoodfacts.org/product/\(code)")
    }

    /// The hit with an ALL CAPS name and brand title-cased, like ``FoodDraft/displayCased``.
    public var displayCased: OFFSearchHit {
        var hit = self
        hit.name = name.map(FoodNameCasing.titleCasedIfAllCaps)
        hit.nameLocal = nameLocal.map(FoodNameCasing.titleCasedIfAllCaps)
        hit.brand = brand.map(FoodNameCasing.titleCasedIfAllCaps)
        return hit
    }
}

/// Full-text search over Open Food Facts packaged products (SPEC §3.1, FR-20). A protocol so online search can be
/// tested with a stub.
public protocol OpenFoodFactsSearchClient: Sendable {
    /// End of the throttling cool-down while it lasts, else `nil` — for the "Open Food Facts paused" notice.
    var rateLimitedUntil: Date? { get }

    /// Products matching `query` that have nutrition facts, named in `nameLanguage` (Settings → Food names,
    /// resolved), in OFF's order. Hits without a valid retail barcode are left out. A blank query returns `[]`
    /// without a request.
    ///
    /// Throws ``OpenFoodFactsError`` (never `.notFound` or `.invalidBarcode`; `.rateLimited` during the cool-down,
    /// without a request), or `CancellationError` when the task is cancelled.
    func search(query: String, nameLanguage: FoodNameLanguage) async throws -> [OFFSearchHit]
}

/// Client-side pacing for OFF search, shared by every copy of a client: at most one request per
/// ``minimumInterval`` and none at all during a cool-down after OFF throttled us. In memory only.
public final class OFFSearchThrottle: Sendable {
    /// Spacing between requests: Search-a-licious publishes no limit, but a fast typist shouldn't hammer it.
    public let minimumInterval: Duration
    /// Cool-down after HTTP 429 when the response has no usable `Retry-After`.
    public let cooldown: Duration

    private struct State {
        /// When the last request that was actually sent went out (its slot, or the clock if later).
        var lastSent: Date?
        var blockedUntil: Date?
    }

    private let state = Mutex(State())

    public init(minimumInterval: Duration = .milliseconds(500), cooldown: Duration = .seconds(60)) {
        self.minimumInterval = minimumInterval
        self.cooldown = cooldown
    }

    /// The cool-down end when it is later than `now`.
    public func blockedUntil(now: Date) -> Date? {
        state.withLock { state in state.blockedUntil.flatMap { $0 > now ? $0 : nil } }
    }

    /// Starts a cool-down of `duration` (default ``cooldown``) at `now`; returns its end.
    @discardableResult
    public func block(now: Date, for duration: Duration? = nil) -> Date {
        let until = now.addingTimeInterval(Self.seconds(duration ?? cooldown))
        state.withLock { $0.blockedUntil = max($0.blockedUntil ?? until, until) }
        return until
    }

    /// The earliest time a request may go out: `now`, or ``minimumInterval`` after the last request sent. Reserves
    /// nothing, so a search cancelled while waiting for it costs no slot; ``claim(_:now:)`` takes it.
    func nextSlot(now: Date) -> Date {
        state.withLock { state in Self.slot(after: state.lastSent, now: now, interval: Self.seconds(minimumInterval)) }
    }

    /// Takes `slot` for a request about to be sent, when no other request was sent within ``minimumInterval``
    /// before it. Returns `nil` on success, else the later slot to wait for (another waiter sent first).
    func claim(_ slot: Date, now: Date) -> Date? {
        state.withLock { state in
            let interval = Self.seconds(minimumInterval)
            let earliest = Self.slot(after: state.lastSent, now: slot, interval: interval)
            guard earliest <= slot else { return earliest }
            state.lastSent = max(slot, now)
            return nil
        }
    }

    /// How long to wait from `now` until `slot` (zero when it has passed), to the millisecond.
    static func wait(until slot: Date, now: Date) -> Duration {
        .milliseconds(Int((max(0, slot.timeIntervalSince(now)) * 1000).rounded()))
    }

    private static func slot(after lastSent: Date?, now: Date, interval: TimeInterval) -> Date {
        max(now, lastSent.map { $0.addingTimeInterval(interval) } ?? now)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// ``OpenFoodFactsSearchClient`` over Search-a-licious, OFF's Elasticsearch search (SPEC §3.1, §15), which is fast
/// and meant for search as you type — unlike the v1 `cgi/search.pl`, which allows ~10 searches a minute.
///
/// `GET {baseURL}/search?q=…&page_size=…&fields=…` with the same descriptive `User-Agent` as
/// ``OpenFoodFactsHTTPClient``. The query (``luceneQuery(_:)``) matches every word of the user's text in the
/// product's main-language name, English name, generic name or brand, and keeps only products whose nutrition
/// facts are complete. Hits carry no nutrition: the app fetches the product by barcode when one is picked.
///
/// Tuned for typing: a 5 s timeout and **no retries** — a stale answer is useless once the user has typed on.
/// Requests are spaced by ``OFFSearchThrottle/minimumInterval`` (waiting is cancellable), and responses are never
/// stored in `URLCache`. HTTP 429 maps to ``OpenFoodFactsError/rateLimited`` and starts a cool-down (`Retry-After`,
/// else 60 s) during which every search fails at once, without a request. HTTP 503 (overloaded) is
/// ``OpenFoodFactsError/server(status:)``, without a cool-down.
public struct OpenFoodFactsSearchHTTPClient: OpenFoodFactsSearchClient {
    public static let defaultBaseURL = URL(string: "https://search.openfoodfacts.org")!
    /// Per-request timeout, seconds.
    public static let requestTimeout: TimeInterval = 5
    public static let defaultPageSize = 20
    /// Requested per hit: names, brand and package size for the list row.
    static let fields = ["code", "product_name", "product_name_hr", "product_name_en", "generic_name", "brands", "quantity"]

    public let userAgent: String
    public let baseURL: URL
    public let pageSize: Int
    public let throttle: OFFSearchThrottle
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - contact: How OFF can reach the app's maintainer, as for ``OpenFoodFactsHTTPClient``: Info.plist
    ///     `OFFUserAgentContact`, e.g. "https://github.com/memphin/vitalion". Blank falls back to
    ///     `Vitalion/<appVersion>`.
    ///   - appVersion: Goes into the User-Agent, `Vitalion/<appVersion> (<contact>)`.
    ///   - pageSize: Results per search (1…100).
    ///   - transport: Defaults to an uncached `URLSession` with the 5 s timeout.
    ///   - throttle: Shared pacing and cool-down state.
    ///   - now: Clock for the throttle; tests pass a fixed one.
    ///   - sleep: Wait before a paced request; tests pass a recorder.
    public init(
        contact: String,
        appVersion: String = "1.0",
        baseURL: URL = OpenFoodFactsSearchHTTPClient.defaultBaseURL,
        pageSize: Int = OpenFoodFactsSearchHTTPClient.defaultPageSize,
        transport: any HTTPTransport = URLSessionTransport.uncached(timeout: OpenFoodFactsSearchHTTPClient.requestTimeout),
        throttle: OFFSearchThrottle = OFFSearchThrottle(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        userAgent = OpenFoodFactsHTTPClient.userAgent(contact: contact, appVersion: appVersion)
        self.baseURL = baseURL
        self.pageSize = min(max(pageSize, 1), 100)
        self.transport = transport
        self.throttle = throttle
        self.now = now
        self.sleep = sleep
    }

    public var rateLimitedUntil: Date? {
        throttle.blockedUntil(now: now())
    }

    public func search(query: String, nameLanguage: FoodNameLanguage) async throws -> [OFFSearchHit] {
        guard let lucene = Self.luceneQuery(query) else { return [] }
        try Task.checkCancellation()
        if rateLimitedUntil != nil {
            throw OpenFoodFactsError.rateLimited
        }
        // Wait for a free slot, then take it; a search cancelled while waiting never takes one, so a fast typist's
        // abandoned searches don't push later ones back. When another search took the slot first, wait for the next.
        var slot = throttle.nextSlot(now: now())
        while true {
            let wait = OFFSearchThrottle.wait(until: slot, now: now())
            if wait > .zero {
                try await sleep(wait)
            }
            try Task.checkCancellation()
            guard let later = throttle.claim(slot, now: now()) else { break }
            slot = later
        }
        let (data, response) = try await transport.classifiedData(for: request(lucene: lucene))
            .mapError(Self.error)
            .get()

        switch response.statusCode {
        case 200 ..< 300:
            try Task.checkCancellation()
            guard let body = OFFSearchResponse.parse(data) else { throw OpenFoodFactsError.invalidResponse }
            var seen = Set<String>()
            return body.hits.compactMap { product in
                guard let hit = Self.hit(product, language: nameLanguage), seen.insert(hit.code).inserted else { return nil }
                return hit
            }
        case 429:
            throttle.block(now: now(), for: HTTPFailure.retryAfter(response))
            throw OpenFoodFactsError.rateLimited
        default:
            throw OpenFoodFactsError.server(status: response.statusCode)
        }
    }

    /// The search request for the user's `query`; `nil` when it has no searchable words.
    public func request(query: String) -> URLRequest? {
        Self.luceneQuery(query).map { request(lucene: $0) }
    }

    private func request(lucene: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: lucene),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "fields", value: Self.fields.joined(separator: ",")),
        ]
        // URLComponents leaves "+" alone in query values; the server would read it as a space.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        var request = URLRequest(
            url: components?.url ?? baseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout,
        )
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The Lucene query for the user's text: its words (letters and digits only, lowercased, so nothing typed can
    /// act as query syntax or an `AND`/`OR` operator) must all appear in one of the searched fields, and the product
    /// must have complete nutrition facts. `nil` when no word is left.
    ///
    /// Search-a-licious only searches English fields by default; `product_name.main` (the name in the product's
    /// own language) is what finds Croatian products such as "Dorina Mliječna".
    static func luceneQuery(_ text: String) -> String? {
        let words = text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
        guard !words.isEmpty else { return nil }
        let terms = words.joined(separator: " ")
        let fields = ["product_name.main", "product_name.en", "generic_name.en", "brands"]
        let anyField = fields.map { "\($0):(\(terms))" }.joined(separator: " OR ")
        return "(\(anyField)) AND states_tags:\"en:nutrition-facts-completed\""
    }

    /// `product` as a hit, or `nil` without a valid retail barcode (the product lookup needs one).
    static func hit(_ product: OFFProduct, language: FoodNameLanguage) -> OFFSearchHit? {
        guard let code = Barcode.normalize(product.code) else { return nil }
        let names = OFFFoodMapper.names(product, language: language)
        return OFFSearchHit(
            code: code,
            name: names.name,
            nameLocal: names.local,
            brand: OFFFoodMapper.firstBrand(product.brands),
            quantity: product.quantity.trimmedNonEmpty,
        )
    }

    private static func error(_ failure: HTTPFailure) -> OpenFoodFactsError {
        switch failure {
        case .offline, .connectionDropped: .offline
        case .timedOut: .timedOut
        case let .other(code): .network(code)
        }
    }
}

/// Envelope of a Search-a-licious response: `{"hits": [{…}], "count": 3, "page": 1, …}`. Hits are read like
/// products (``OFFProduct``), except that `brands` is a list here; hits that aren't objects are skipped.
struct OFFSearchResponse: Decodable {
    let count: Int?
    let hits: [OFFProduct]

    enum CodingKeys: String, CodingKey {
        case count, hits
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.lenientDouble(.count).flatMap { Int(exactly: $0) }
        guard container.contains(.hits) else {
            throw DecodingError.keyNotFound(CodingKeys.hits, .init(codingPath: [], debugDescription: "not a search response"))
        }
        hits = ((try? container.decode([LenientHit].self, forKey: .hits)) ?? []).compactMap(\.product)
    }

    /// `nil` when `data` isn't a JSON object with a `hits` key.
    static func parse(_ data: Data) -> OFFSearchResponse? {
        try? JSONDecoder().decode(OFFSearchResponse.self, from: data)
    }
}

/// One `hits` element: a product (with `brands` joined from a list), or `nil` for anything that isn't an object.
private struct LenientHit: Decodable {
    let product: OFFProduct?

    private enum CodingKeys: String, CodingKey {
        case brands
    }

    init(from decoder: any Decoder) {
        guard var product = try? OFFProduct(from: decoder) else {
            product = nil
            return
        }
        if let list = try? decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .brands) {
            product.brands = list.joined(separator: ",")
        }
        self.product = product
    }
}
