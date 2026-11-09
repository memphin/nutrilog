import Foundation
import Synchronization

/// Full-text search over Open Food Facts packaged products (SPEC §3.1, FR-20). A protocol so online search can be
/// tested with a stub.
public protocol OpenFoodFactsSearchClient: Sendable {
    /// End of the throttling cool-down while it lasts, else `nil` — for the "Open Food Facts paused" notice.
    var rateLimitedUntil: Date? { get }

    /// Products matching `query`, mapped by ``OFFFoodMapper``, in OFF's order. Products without a code or without
    /// any nutrition are left out. A blank query returns `[]` without a request.
    ///
    /// Throws ``OpenFoodFactsError`` (never `.notFound` or `.invalidBarcode`; `.rateLimited` during the cool-down,
    /// without a request), or `CancellationError` when the task is cancelled.
    func search(query: String) async throws -> [FoodDraft]
}

/// Client-side pacing for OFF search, shared by every copy of a client: at most one request per
/// ``minimumInterval`` and none at all during a cool-down after OFF throttled us. In memory only.
public final class OFFSearchThrottle: Sendable {
    /// OFF documents ~10 searches a minute; spacing requests keeps a fast typist from being blocked.
    public let minimumInterval: Duration
    public let cooldown: Duration

    private struct State {
        var nextAllowed: Date?
        var blockedUntil: Date?
    }

    private let state = Mutex(State())

    public init(minimumInterval: Duration = .milliseconds(1500), cooldown: Duration = .seconds(60)) {
        self.minimumInterval = minimumInterval
        self.cooldown = cooldown
    }

    /// The cool-down end when it is later than `now`.
    public func blockedUntil(now: Date) -> Date? {
        state.withLock { state in state.blockedUntil.flatMap { $0 > now ? $0 : nil } }
    }

    /// Starts the cool-down at `now`; returns its end.
    @discardableResult
    public func block(now: Date) -> Date {
        let until = now.addingTimeInterval(Self.seconds(cooldown))
        state.withLock { $0.blockedUntil = max($0.blockedUntil ?? until, until) }
        return until
    }

    /// Reserves the next request slot: how long to wait before sending (zero when the interval has passed).
    func reserveSlot(now: Date) -> Duration {
        state.withLock { state in
            let slot = max(now, state.nextAllowed ?? now)
            state.nextAllowed = slot.addingTimeInterval(Self.seconds(minimumInterval))
            return .milliseconds(Int((slot.timeIntervalSince(now) * 1000).rounded()))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// ``OpenFoodFactsSearchClient`` over OFF's v1 full-text search (SPEC §3.1, §15) — the v2 search is filter-only.
///
/// `GET {baseURL}/cgi/search.pl?search_terms=…&search_simple=1&json=1&page_size=…&fields=<OFFProduct.fields>` with
/// the same descriptive `User-Agent` as ``OpenFoodFactsHTTPClient``. OFF search is slow and limited to about
/// 10 requests a minute, so this is tuned for typing: a 5 s timeout and **no retries** — a stale answer is useless
/// once the user has typed on, and the next keystroke asks again anyway. Requests are spaced by
/// ``OFFSearchThrottle/minimumInterval`` (waiting is cancellable), and responses are never stored in `URLCache`.
///
/// OFF answers throttled searches with HTTP 503 and an HTML page (seen while capturing the fixtures) or 429; both
/// map to ``OpenFoodFactsError/rateLimited`` and start a cool-down (60 s by default) during which every search
/// fails at once with `.rateLimited`, without a request.
public struct OpenFoodFactsSearchHTTPClient: OpenFoodFactsSearchClient {
    /// Per-request timeout, seconds.
    public static let requestTimeout: TimeInterval = 5
    public static let defaultPageSize = 20

    public let userAgent: String
    public let baseURL: URL
    public let pageSize: Int
    public let throttle: OFFSearchThrottle
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - userAgent: Full `User-Agent`, e.g. `Nutrilog/1.0 (https://github.com/memphin/nutrilog)` (OFF terms,
    ///     SPEC §10). A blank value falls back to `Nutrilog/1.0`.
    ///   - pageSize: Results per search (1…100).
    ///   - transport: Defaults to an uncached `URLSession` with the 5 s timeout.
    ///   - throttle: Shared pacing and cool-down state.
    ///   - now: Clock for the throttle; tests pass a fixed one.
    ///   - sleep: Wait before a paced request; tests pass a recorder.
    public init(
        userAgent: String,
        baseURL: URL = OpenFoodFactsHTTPClient.defaultBaseURL,
        pageSize: Int = OpenFoodFactsSearchHTTPClient.defaultPageSize,
        transport: any HTTPTransport = URLSessionTransport.uncached(timeout: OpenFoodFactsSearchHTTPClient.requestTimeout),
        throttle: OFFSearchThrottle = OFFSearchThrottle(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        let userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = userAgent.isEmpty ? "Nutrilog/1.0" : userAgent
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

    public func search(query: String) async throws -> [FoodDraft] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        try Task.checkCancellation()
        if rateLimitedUntil != nil {
            throw OpenFoodFactsError.rateLimited
        }
        let wait = throttle.reserveSlot(now: now())
        if wait > .zero {
            try await sleep(wait)
        }
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request(query: query))
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw Self.error(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenFoodFactsError.network(.unknown)
        }

        switch response.statusCode {
        case 200 ..< 300:
            try Task.checkCancellation()
            guard let body = OFFSearchResponse.parse(data) else { throw OpenFoodFactsError.invalidResponse }
            return body.products.compactMap(Self.draft)
        case 429, 503:
            throttle.block(now: now())
            throw OpenFoodFactsError.rateLimited
        default:
            throw OpenFoodFactsError.server(status: response.statusCode)
        }
    }

    /// The search request for `query`.
    public func request(query: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "cgi/search.pl"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "fields", value: OFFProduct.fields.joined(separator: ",")),
        ]
        // URLComponents leaves "+" alone in query values; OFF (CGI) would read it as a space.
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

    /// `product` as a draft, or `nil` when it can't be stored or logged: no code (the copy is keyed by it) or no
    /// nutrition at all.
    static func draft(_ product: OFFProduct) -> FoodDraft? {
        guard !product.code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let draft = OFFFoodMapper.map(product)
        guard draft.missingNutrients.count < FoodDraft.MandatoryNutrient.allCases.count else { return nil }
        return draft
    }

    private static func error(_ error: URLError) -> OpenFoodFactsError {
        switch HTTPFailure.classify(error) {
        case .offline, .connectionDropped: .offline
        case .timedOut: .timedOut
        case let .other(code): .network(code)
        }
    }
}

/// Envelope of a v1 search response: `{"count": 1084, "page": 1, "page_size": 20, "products": [{…}], …}`.
/// `count` arrives as a number or a string; products that aren't objects are skipped.
struct OFFSearchResponse: Decodable {
    let count: Int?
    let products: [OFFProduct]

    enum CodingKeys: String, CodingKey {
        case count, products
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.lenientDouble(.count).flatMap { Int(exactly: $0) }
        guard container.contains(.products) else {
            throw DecodingError.keyNotFound(
                CodingKeys.products,
                .init(codingPath: [], debugDescription: "not a search response"),
            )
        }
        products = ((try? container.decode([LenientProduct].self, forKey: .products)) ?? []).compactMap(\.product)
    }

    /// `nil` when `data` isn't a JSON object with a `products` key.
    static func parse(_ data: Data) -> OFFSearchResponse? {
        try? JSONDecoder().decode(OFFSearchResponse.self, from: data)
    }
}

/// One `products` element: a product, or `nil` for anything that isn't an object.
private struct LenientProduct: Decodable {
    let product: OFFProduct?

    init(from decoder: any Decoder) {
        product = try? OFFProduct(from: decoder)
    }
}
