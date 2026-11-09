import Foundation

/// Sends one HTTP request. The seam that lets tests and previews replace the network; online clients take one in
/// their initializer.
public protocol HTTPTransport: Sendable {
    /// Throws `URLError` for network failures; non-2xx statuses are returned, not thrown.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// ``HTTPTransport`` over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// A dedicated session that fails fast instead of waiting for connectivity, with `timeout` seconds as both the
    /// idle and the whole-transfer limit.
    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Like ``init(timeout:)``, but nothing touches disk: an ephemeral session with no `URLCache`, cookies or
    /// credential storage. For requests that carry a secret (the USDA key header) — `URLCache` stores request
    /// headers in Cache.db along with the response.
    public static func uncached(timeout: TimeInterval) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Retry settings shared by the online clients: only fast failures (dropped or refused connections, HTTP 5xx, a short
/// HTTP 429 `Retry-After`) are retried, with exponential backoff.
public struct HTTPRetryPolicy: Hashable, Sendable {
    /// Extra attempts after the first.
    public var maxRetries: Int
    /// Delay before the first retry; doubles for each further retry.
    public var baseDelay: Duration
    /// Longest `Retry-After` on HTTP 429 still worth waiting for; longer ones fail with `.rateLimited`.
    public var maxRetryAfter: Duration

    public init(maxRetries: Int = 2, baseDelay: Duration = .milliseconds(500), maxRetryAfter: Duration = .seconds(2)) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxRetryAfter = maxRetryAfter
    }

    public static let standard = HTTPRetryPolicy()

    /// Delay before retry number `retry` (0-based).
    public func delay(beforeRetry retry: Int) -> Duration {
        baseDelay * (1 << min(retry, 16))
    }
}

/// Transport failure classification shared by the online clients; each maps the cases to its own error type.
enum HTTPFailure: Equatable {
    /// No connection at all: fail at once.
    case offline
    /// The request timeout fired: not retried.
    case timedOut
    /// The connection dropped or the host couldn't be reached: worth a retry.
    case connectionDropped
    case other(URLError.Code)

    /// `URLError.cancelled` is not classified here: callers turn it into `CancellationError` first.
    static func classify(_ error: URLError) -> HTTPFailure {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            .offline
        case .timedOut:
            .timedOut
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            .connectionDropped
        default:
            .other(error.code)
        }
    }

    /// `Retry-After` in seconds; `nil` when absent or an HTTP date (treated as too long to wait).
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Int(text), seconds >= 0
        else {
            return nil
        }
        return .seconds(seconds)
    }
}
