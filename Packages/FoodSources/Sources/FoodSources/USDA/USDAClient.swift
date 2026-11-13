import Foundation
import Synchronization

/// Why a USDA FoodData Central search failed. No case carries the API key, a URL or server text, so an error can
/// be logged or shown as is.
public enum USDAError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No API key is configured; no request was made. The source is unavailable (`isAvailable == false`).
    case missingAPIKey
    /// FDC rejected the key (HTTP 401/403, `API_KEY_INVALID`, `API_KEY_DISABLED`, …).
    case invalidAPIKey
    /// FDC answered HTTP 429. Every search fails with this, without a request, until `until` (now + 1 h).
    case rateLimited(until: Date)
    /// No connection, or FDC couldn't be reached after the retries.
    case offline
    /// The request hit the timeout (not retried).
    case timedOut
    /// An HTTP error status other than 401/403/429 (5xx after the retries).
    case server(status: Int)
    /// Any other network failure.
    case network(URLError.Code)
    /// A 2xx response whose body isn't a search result.
    case invalidResponse

    public var description: String {
        switch self {
        case .missingAPIKey: "USDA FoodData Central: no API key"
        case .invalidAPIKey: "USDA FoodData Central: the API key was rejected"
        case let .rateLimited(until): "USDA FoodData Central: rate limited until \(until.formatted(.iso8601))"
        case .offline: "USDA FoodData Central: offline"
        case .timedOut: "USDA FoodData Central: timed out"
        case let .server(status): "USDA FoodData Central: HTTP \(status)"
        case let .network(code): "USDA FoodData Central: network error \(code.rawValue)"
        case .invalidResponse: "USDA FoodData Central: invalid response"
        }
    }
}

/// Searches USDA FoodData Central. A protocol so online search (#22) can be tested with a stub.
public protocol USDAClient: Sendable {
    /// False without an API key: the source is hidden and ``search(query:)`` throws ``USDAError/missingAPIKey``.
    var isAvailable: Bool { get }
    /// End of the HTTP 429 cool-down while it lasts, else `nil` — for the "USDA paused" notice.
    var rateLimitedUntil: Date? { get }
    /// Foundation, SR Legacy and Branded foods matching `query`, in FDC's relevance order. A blank query returns
    /// `[]` without a request, before any key or cool-down check.
    ///
    /// Throws ``USDAError``, or `CancellationError` when the task is cancelled.
    func search(query: String) async throws -> [FoodDraft]
}

/// In-memory "rate limited until" shared by every copy of a client (and across clients that are given the same
/// instance). Not persisted: a relaunch forgets it, and the next 429 sets it again.
public final class USDARateLimit: Sendable {
    private let until = Mutex<Date?>(nil)

    public init() {}

    /// The cool-down end when it is later than `now`.
    public func blockedUntil(now: Date) -> Date? {
        until.withLock { until in until.flatMap { $0 > now ? $0 : nil } }
    }

    /// Starts (or extends) the cool-down until `date`.
    public func block(until date: Date) {
        until.withLock { $0 = max($0 ?? date, date) }
    }

    /// Ends the cool-down, e.g. when a different key is configured.
    public func reset() {
        until.withLock { $0 = nil }
    }
}

/// ``USDAClient`` over the FDC REST API (SPEC §3.2, §10, §15, ADR-0004).
///
/// `GET {baseURL}/v1/foods/search?query=…&dataType=Foundation,SR Legacy,Branded&pageSize=…` with the key in the
/// `X-Api-Key` header (api.data.gov accepts it there), so it never appears in a URL, a cache key or an error.
/// Retries like ``OpenFoodFactsHTTPClient``: dropped connections and HTTP 5xx, up to 2 times with backoff.
/// HTTP 429 is never retried: FDC blocks the key for an hour, so the client stops asking for ``cooldown``.
///
/// The key is never logged: `description`, `debugDescription` and `Mirror` (`dump`) leave it out.
public struct USDAHTTPClient: USDAClient {
    public static let defaultBaseURL = URL(string: "https://api.nal.usda.gov/fdc")!
    /// Per-request timeout, seconds. Longer than OFF's barcode lookup: a typed search can wait a little.
    public static let requestTimeout: TimeInterval = 10
    /// FDC data types searched; Survey (FNDDS) is left out (mixed dishes as eaten, mostly duplicates of SR Legacy).
    public static let dataTypes = ["Foundation", "SR Legacy", "Branded"]
    /// FDC blocks a key for an hour after it exceeds the limit (SPEC §3.2).
    public static let defaultCooldown: Duration = .seconds(3600)

    private let apiKey: String?
    public let baseURL: URL
    public let pageSize: Int
    public let retryPolicy: HTTPRetryPolicy
    public let cooldown: Duration
    public let rateLimit: USDARateLimit
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - apiKey: FDC key; `nil` or blank makes the client unavailable.
    ///   - pageSize: Results per search (FDC allows 1…200).
    ///   - rateLimit: Shared cool-down state; pass the same instance to keep it across rebuilt clients.
    ///   - now: Clock for the cool-down; tests pass a fixed one.
    ///   - sleep: Backoff wait; tests pass a recorder.
    public init(
        apiKey: String?,
        baseURL: URL = USDAHTTPClient.defaultBaseURL,
        pageSize: Int = 25,
        transport: any HTTPTransport = USDAHTTPClient.makeDefaultTransport(),
        retryPolicy: HTTPRetryPolicy = .standard,
        cooldown: Duration = USDAHTTPClient.defaultCooldown,
        rateLimit: USDARateLimit = USDARateLimit(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (key?.isEmpty ?? true) ? nil : key
        self.baseURL = baseURL
        self.pageSize = min(max(pageSize, 1), 200)
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.cooldown = cooldown
        self.rateLimit = rateLimit
        self.now = now
        self.sleep = sleep
    }

    /// An ephemeral `URLSession` with no `URLCache`: the request's `X-Api-Key` header must never reach Cache.db.
    public static func makeDefaultTransport() -> URLSessionTransport {
        .uncached(timeout: requestTimeout)
    }

    public var isAvailable: Bool {
        apiKey != nil
    }

    public var rateLimitedUntil: Date? {
        rateLimit.blockedUntil(now: now())
    }

    public func search(query: String) async throws -> [FoodDraft] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let apiKey = try usableKey()
        return try await send(request(query: query, apiKey: apiKey)).compactMap(FDCFoodMapper.map)
    }

    /// The key, unless there is none or the cool-down is running.
    private func usableKey() throws -> String {
        guard let apiKey else { throw USDAError.missingAPIKey }
        if let until = rateLimitedUntil {
            throw USDAError.rateLimited(until: until)
        }
        return apiKey
    }

    /// Sends `request`, retrying per ``retryPolicy``.
    private func send(_ request: URLRequest) async throws -> [FDCFood] {
        try await retryPolicy.run(sleep: sleep) {
            switch try await transport.classifiedData(for: request) {
            case let .success((data, response)): outcome(data: data, response: response)
            case let .failure(failure): Self.outcome(failure)
            }
        }
    }

    /// The search request for `query`. The key goes in the `X-Api-Key` header, never in the URL.
    func request(query: String, apiKey: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "v1/foods/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "dataType", value: Self.dataTypes.joined(separator: ",")),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        var request = URLRequest(
            url: components?.url ?? baseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout,
        )
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `url` with the value of every `api_key` query item replaced by "REDACTED", for anything that shows or logs
    /// a URL (a `baseURL` pointing at a proxy might carry one).
    public static func redacted(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { $0.name.lowercased() == "api_key" })
        else {
            return url
        }
        components.queryItems = items.map { item in
            item.name.lowercased() == "api_key" ? URLQueryItem(name: item.name, value: "REDACTED") : item
        }
        return components.url ?? url
    }

    // MARK: - Outcome

    private typealias Outcome = HTTPAttempt<[FDCFood], USDAError>

    private func outcome(data: Data, response: HTTPURLResponse) -> Outcome {
        switch response.statusCode {
        case 200 ..< 300:
            guard let body = FDCSearchResponse.parse(data) else { return .failure(.invalidResponse) }
            return .success(body.foods)
        case 401, 403:
            // api.data.gov answers 403 for a missing, invalid or disabled key, and also for OVER_RATE_LIMIT on
            // some deployments.
            if FDCErrorResponse.code(in: data) == "OVER_RATE_LIMIT" {
                return .failure(startCooldown())
            }
            return .failure(.invalidAPIKey)
        case 429:
            return .failure(startCooldown())
        case 500 ..< 600:
            return .retryable(.server(status: response.statusCode))
        default:
            return .failure(.server(status: response.statusCode))
        }
    }

    private func startCooldown() -> USDAError {
        let until = now().addingTimeInterval(TimeInterval(cooldown.components.seconds))
        rateLimit.block(until: until)
        return .rateLimited(until: rateLimit.blockedUntil(now: now()) ?? until)
    }

    private static func outcome(_ failure: HTTPFailure) -> Outcome {
        switch failure {
        case .offline: .failure(.offline)
        case .timedOut: .failure(.timedOut)
        case .connectionDropped: .retryable(.offline)
        case let .other(code): .failure(.network(code))
        }
    }
}

// MARK: - Key-safe descriptions

extension USDAHTTPClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "USDAHTTPClient(baseURL: \(Self.redacted(baseURL)), apiKey: \(apiKey == nil ? "none" : "set"))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "baseURL": Self.redacted(baseURL),
            "isAvailable": isAvailable,
            "pageSize": pageSize,
        ])
    }
}
