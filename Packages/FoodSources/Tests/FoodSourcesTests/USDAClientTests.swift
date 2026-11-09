import Foundation
import Synchronization
import Testing
@testable import FoodSources

/// Settable clock for the 429 cool-down.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var closure: @Sendable () -> Date {
        { [self] in now }
    }
}

struct USDAClientTests {
    private static let key = "not-a-real-usda-key"

    private func makeClient(
        _ transport: StubTransport,
        key: String? = USDAClientTests.key,
        clock: TestClock = TestClock(),
        sleeper: SleepRecorder = SleepRecorder(),
    ) -> USDAHTTPClient {
        USDAHTTPClient(apiKey: key, transport: transport, now: clock.closure, sleep: sleeper.sleep)
    }

    private func usda(_ name: String) throws -> Data {
        try Fixture.data(name, in: "USDA")
    }

    // MARK: - Request

    @Test func `request: foods/search, three data types, page size, key only in the X-Api-Key header`() throws {
        let client = USDAHTTPClient(apiKey: Self.key, pageSize: 30)
        let request = client.request(query: "cheddar cheese", apiKey: Self.key)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "api.nal.usda.gov")
        #expect(components.path == "/fdc/v1/foods/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["query"] == "cheddar cheese")
        #expect(items["dataType"] == "Foundation,SR Legacy,Branded")
        #expect(items["pageSize"] == "30")
        #expect(items["api_key"] == nil)
        #expect(!url.absoluteString.contains(Self.key))
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == Self.key)
        #expect(request.timeoutInterval == 10)
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func `default transport has no URLCache, so the key header never reaches Cache.db`() {
        let configuration = USDAHTTPClient.makeDefaultTransport().session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 10)
    }

    @Test func `OFF keeps its default cached session`() {
        let configuration = URLSessionTransport(timeout: 8).session.configuration
        #expect(configuration.urlCache != nil)
    }

    @Test func `search maps the results`() async throws {
        let transport = try StubTransport([.http(200, usda("search_mixed"))])
        let foods = try await makeClient(transport).search(query: "  cheddar cheese ")
        #expect(foods.map(\.sourceID) == ["2095236", "1750341", "175032"])
        #expect(foods.allSatisfy { $0.origin == .usda })
        let url = try #require(transport.requests.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "cheddar cheese")
    }

    @Test func `blank query returns nothing without a request`() async throws {
        let transport = try StubTransport([.http(200, usda("search_mixed"))])
        #expect(try await makeClient(transport).search(query: "   ").isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func `blank query returns nothing even without a key or during the cool-down`() async throws {
        let transport = try StubTransport([.http(200, usda("search_mixed"))])
        #expect(try await makeClient(transport, key: nil).search(query: "").isEmpty)
        let clock = TestClock()
        let rateLimit = USDARateLimit()
        rateLimit.block(until: clock.now.addingTimeInterval(60))
        let limited = USDAHTTPClient(apiKey: Self.key, transport: transport, rateLimit: rateLimit, now: clock.closure)
        #expect(try await limited.search(query: " ").isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func `reset ends the cool-down`() {
        let clock = TestClock()
        let rateLimit = USDARateLimit()
        rateLimit.block(until: clock.now.addingTimeInterval(60))
        #expect(rateLimit.blockedUntil(now: clock.now) != nil)
        rateLimit.reset()
        #expect(rateLimit.blockedUntil(now: clock.now) == nil)
    }

    // MARK: - Missing key

    @Test(arguments: [nil, "", "   \n"])
    func `without a key the source is unavailable and search makes no request`(key: String?) async throws {
        let transport = try StubTransport([.http(200, usda("search_mixed"))])
        let client = makeClient(transport, key: key)
        #expect(!client.isAvailable)
        await #expect(throws: USDAError.missingAPIKey) {
            try await client.search(query: "apple")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func `with a key the source is available`() {
        #expect(USDAHTTPClient(apiKey: " \(Self.key) ").isAvailable)
    }

    // MARK: - 429 cool-down

    @Test func `http 429 starts a one-hour cool-down; searches fail without requests until it ends`() async throws {
        let clock = TestClock()
        let start = clock.now
        let transport = try StubTransport([.http(429, usda("error_over_rate_limit")), .http(200, usda("search_mixed"))])
        let client = makeClient(transport, clock: clock)
        let until = start.addingTimeInterval(3600)

        await #expect(throws: USDAError.rateLimited(until: until)) {
            try await client.search(query: "apple")
        }
        #expect(transport.requests.count == 1) // not retried
        #expect(client.rateLimitedUntil == until)
        #expect(client.isAvailable) // still has a key: the UI shows a "paused" notice instead of hiding the source

        clock.advance(by: 3599)
        await #expect(throws: USDAError.rateLimited(until: until)) {
            try await client.search(query: "apple")
        }
        #expect(transport.requests.count == 1)

        clock.advance(by: 1)
        #expect(client.rateLimitedUntil == nil)
        let foods = try await client.search(query: "apple")
        #expect(foods.count == 3)
        #expect(transport.requests.count == 2)
    }

    @Test func `the cool-down is shared by copies and by clients given the same rate limit`() async throws {
        let clock = TestClock()
        let rateLimit = USDARateLimit()
        let transport = StubTransport([.http(429, Data())])
        let first = USDAHTTPClient(apiKey: Self.key, transport: transport, rateLimit: rateLimit, now: clock.closure)
        let copy = first
        let other = USDAHTTPClient(apiKey: Self.key, transport: transport, rateLimit: rateLimit, now: clock.closure)
        _ = try? await first.search(query: "apple")
        #expect(copy.rateLimitedUntil != nil)
        await #expect(throws: USDAError.self) { try await other.search(query: "apple") }
        #expect(transport.requests.count == 1)
    }

    @Test func `http 403 OVER_RATE_LIMIT also starts the cool-down`() async throws {
        let clock = TestClock()
        let transport = try StubTransport([.http(403, usda("error_over_rate_limit"))])
        let client = makeClient(transport, clock: clock)
        await #expect(throws: USDAError.rateLimited(until: clock.now.addingTimeInterval(3600))) {
            try await client.search(query: "apple")
        }
        #expect(client.rateLimitedUntil != nil)
    }

    // MARK: - Other failures

    @Test(arguments: [401, 403])
    func `rejected key`(status: Int) async throws {
        let transport = try StubTransport([.http(status, usda("error_invalid_key"))])
        let client = makeClient(transport)
        await #expect(throws: USDAError.invalidAPIKey) {
            try await client.search(query: "apple")
        }
        #expect(client.rateLimitedUntil == nil)
    }

    @Test func `http 5xx is retried with backoff, then succeeds`() async throws {
        let sleeper = SleepRecorder()
        let transport = try StubTransport([.http(503, Data()), .http(502, Data()), .http(200, usda("search_empty"))])
        let foods = try await makeClient(transport, sleeper: sleeper).search(query: "xyzzyqwerty")
        #expect(foods.isEmpty)
        #expect(transport.requests.count == 3)
        #expect(sleeper.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test func `http 5xx after the retries is a server error`() async throws {
        let transport = StubTransport([.http(500, Data())])
        await #expect(throws: USDAError.server(status: 500)) {
            try await makeClient(transport).search(query: "apple")
        }
        #expect(transport.requests.count == 3)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, USDAError.offline, 1),
        (.timedOut, .timedOut, 1),
        (.networkConnectionLost, .offline, 3),
        (.badURL, .network(.badURL), 1),
    ])
    func `network failures`(code: URLError.Code, expected: USDAError, attempts: Int) async throws {
        let transport = StubTransport([.failure(code)])
        await #expect(throws: expected) {
            try await makeClient(transport).search(query: "apple")
        }
        #expect(transport.requests.count == attempts)
    }

    @Test func `cancelled request throws CancellationError`() async throws {
        let transport = StubTransport([.failure(.cancelled)])
        await #expect(throws: CancellationError.self) {
            try await makeClient(transport).search(query: "apple")
        }
    }

    @Test(arguments: ["not json", "[]", #"{"totalHits": 1}"#, #"{"foods": "oops"}"#])
    func `unusable 2xx body is invalidResponse`(body: String) async throws {
        let transport = StubTransport([.http(200, Data(body.utf8))])
        await #expect(throws: USDAError.invalidResponse) {
            try await makeClient(transport).search(query: "apple")
        }
    }

    @Test func `other 4xx is a server error`() async throws {
        let transport = StubTransport([.http(400, Data())])
        await #expect(throws: USDAError.server(status: 400)) {
            try await makeClient(transport).search(query: "apple")
        }
        #expect(transport.requests.count == 1)
    }

    // MARK: - Key never leaks

    @Test func `client descriptions, debug output and dump leave the key out`() {
        let client = USDAHTTPClient(apiKey: Self.key)
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
            #expect(!text.contains(Self.key), "\(text)")
        }
        #expect(String(describing: client).contains("apiKey: set"))
    }

    @Test func `error descriptions never contain the key`() async throws {
        let errors: [USDAError] = [
            .missingAPIKey, .invalidAPIKey, .rateLimited(until: Date()), .offline, .timedOut, .server(status: 500),
            .network(.badURL), .invalidResponse,
        ]
        for error in errors {
            #expect(!String(describing: error).contains(Self.key))
            #expect(!error.localizedDescription.contains(Self.key))
        }
        // A thrown error keeps no URL: the failing URL of a URLError is dropped.
        let transport = StubTransport([.failure(.badServerResponse)])
        do {
            _ = try await makeClient(transport).search(query: "apple")
            Issue.record("expected an error")
        } catch {
            var dumped = ""
            dump(error, to: &dumped)
            #expect(!dumped.contains(Self.key))
            #expect(!String(reflecting: error).contains(Self.key))
        }
    }

    @Test func `redacted replaces api_key query values`() throws {
        let url = try #require(URL(string: "https://proxy.example/fdc?api_key=\(Self.key)&x=1&API_KEY=abc"))
        let redacted = USDAHTTPClient.redacted(url).absoluteString
        #expect(!redacted.contains(Self.key))
        #expect(!redacted.contains("abc"))
        #expect(redacted.contains("api_key=REDACTED"))
        #expect(redacted.contains("x=1"))
        let plain = try #require(URL(string: "https://api.nal.usda.gov/fdc"))
        #expect(USDAHTTPClient.redacted(plain) == plain)
        let proxy = USDAHTTPClient(apiKey: nil, baseURL: url)
        #expect(!String(describing: proxy).contains(Self.key))
    }
}
