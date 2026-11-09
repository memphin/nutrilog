import Foundation

/// Why an Open Food Facts lookup failed.
public enum OpenFoodFactsError: Error, Hashable, Sendable {
    /// The code isn't 8–14 digits; no request was made.
    case invalidBarcode
    /// OFF has no product for this code (`status: 0`, or HTTP 404).
    case notFound
    /// No connection, or OFF couldn't be reached after the retries.
    case offline
    /// Every attempt hit the request timeout.
    case timedOut
    /// HTTP 429 after the retries.
    case rateLimited
    /// An HTTP error status other than 404/429 (5xx after the retries).
    case server(status: Int)
    /// Any other network failure.
    case network(URLError.Code)
    /// A 2xx response whose body isn't a usable product.
    case invalidResponse
}

/// Looks up packaged foods on Open Food Facts. A protocol so the barcode pipeline and online search can be tested
/// with a stub.
public protocol OpenFoodFactsClient: Sendable {
    /// The product for `barcode` (digits only; normalize with `Core.Barcode` first).
    ///
    /// Throws ``OpenFoodFactsError``, or `CancellationError` when the task is cancelled.
    func product(barcode: String) async throws -> OFFProduct
}

public extension OpenFoodFactsClient {
    /// ``product(barcode:)`` mapped by ``OFFFoodMapper``.
    func food(barcode: String) async throws -> FoodDraft {
        try await OFFFoodMapper.map(product(barcode: barcode))
    }
}

/// ``OpenFoodFactsClient`` over the OFF v2 REST API (SPEC §3.1, §9, §15).
///
/// `GET {baseURL}/api/v2/product/{code}.json?fields=<OFFProduct.fields>` with a descriptive `User-Agent`
/// (OFF terms, SPEC §10), an 8 s timeout and up to 2 retries with exponential backoff for timeouts, dropped
/// connections, HTTP 429 and 5xx. No connection at all fails at once with ``OpenFoodFactsError/offline``.
public struct OpenFoodFactsHTTPClient: OpenFoodFactsClient {
    public struct RetryPolicy: Hashable, Sendable {
        /// Extra attempts after the first.
        public var maxRetries: Int
        /// Delay before the first retry; doubles for each further retry.
        public var baseDelay: Duration

        public init(maxRetries: Int = 2, baseDelay: Duration = .milliseconds(500)) {
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
        }

        public static let standard = RetryPolicy()

        /// Delay before retry number `retry` (0-based).
        public func delay(beforeRetry retry: Int) -> Duration {
            baseDelay * (1 << min(retry, 16))
        }
    }

    public static let defaultBaseURL = URL(string: "https://world.openfoodfacts.org")!
    /// Per-request timeout, seconds.
    public static let requestTimeout: TimeInterval = 8

    public let userAgent: String
    public let baseURL: URL
    public let retryPolicy: RetryPolicy
    private let transport: any HTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - contact: How OFF can reach the app's maintainer: Info.plist `OFFUserAgentContact`, e.g.
    ///     "https://github.com/memphin/nutrilog".
    ///   - appVersion: Goes into the User-Agent, `Nutrilog/<appVersion> (<contact>)`.
    ///   - transport: Defaults to a `URLSession` with the 8 s timeout.
    ///   - sleep: Backoff wait; tests pass a no-op.
    public init(
        contact: String,
        appVersion: String = "1.0",
        baseURL: URL = OpenFoodFactsHTTPClient.defaultBaseURL,
        transport: any HTTPTransport = URLSessionTransport(timeout: OpenFoodFactsHTTPClient.requestTimeout),
        retryPolicy: RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        let contact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        userAgent = contact.isEmpty ? "Nutrilog/\(appVersion)" : "Nutrilog/\(appVersion) (\(contact))"
        self.baseURL = baseURL
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public func product(barcode: String) async throws -> OFFProduct {
        guard (8 ... 14).contains(barcode.count), barcode.allSatisfy({ ("0" ... "9").contains($0) }) else {
            throw OpenFoodFactsError.invalidBarcode
        }
        let request = request(barcode: barcode)
        var retry = 0
        while true {
            try Task.checkCancellation()
            let outcome: Outcome
            do {
                let (data, response) = try await transport.data(for: request)
                outcome = Self.outcome(data: data, response: response, barcode: barcode)
            } catch let error as URLError {
                if error.code == .cancelled {
                    throw CancellationError()
                }
                outcome = Self.outcome(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failure(.network(.unknown))
            }

            switch outcome {
            case let .success(product):
                return product
            case let .failure(error):
                throw error
            case let .retryable(error):
                guard retry < retryPolicy.maxRetries else { throw error }
                try await sleep(retryPolicy.delay(beforeRetry: retry))
                retry += 1
            }
        }
    }

    /// The product request for `barcode`.
    public func request(barcode: String) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v2/product/\(barcode).json"),
            resolvingAgainstBaseURL: false,
        )
        components?.queryItems = [URLQueryItem(name: "fields", value: OFFProduct.fields.joined(separator: ","))]
        var request = URLRequest(
            url: components?.url ?? baseURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: Self.requestTimeout,
        )
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Outcome

    private enum Outcome {
        case success(OFFProduct)
        case failure(OpenFoodFactsError)
        case retryable(OpenFoodFactsError)
    }

    /// OFF signals "not found" with `status: 0`, with HTTP 200 or 404 — the body wins over the HTTP status (SPEC §3.1).
    private static func outcome(data: Data, response: HTTPURLResponse, barcode: String) -> Outcome {
        let body = OFFProductResponse.parse(data)
        if body?.status == 0 {
            return .failure(.notFound)
        }
        switch response.statusCode {
        case 200 ..< 300:
            guard let body, body.status == 1, var product = body.product else {
                return .failure(.invalidResponse)
            }
            if product.code.isEmpty {
                product.code = body.code ?? barcode
            }
            return .success(product)
        case 404:
            return .failure(.notFound)
        case 429:
            return .retryable(.rateLimited)
        case 500 ..< 600:
            return .retryable(.server(status: response.statusCode))
        default:
            return .failure(.server(status: response.statusCode))
        }
    }

    private static func outcome(_ error: URLError) -> Outcome {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            .failure(.offline)
        case .timedOut:
            .retryable(.timedOut)
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            .retryable(.offline)
        default:
            .failure(.network(error.code))
        }
    }
}
