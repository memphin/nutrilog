import Foundation
import Testing
@testable import FoodSources

struct OpenFoodFactsClientTests {
    private static let contact = "https://github.com/memphin/nutrilog"
    private static let nutella = "3017620422003"

    private func makeClient(_ transport: StubTransport, sleeper: SleepRecorder = SleepRecorder()) -> OpenFoodFactsHTTPClient {
        OpenFoodFactsHTTPClient(contact: Self.contact, transport: transport, sleep: sleeper.sleep)
    }

    // MARK: - Request

    @Test func `request uses the v2 product endpoint, fields allowlist, User-Agent and 8 s timeout`() throws {
        let client = OpenFoodFactsHTTPClient(contact: Self.contact, appVersion: "1.2")
        let request = client.request(barcode: Self.nutella)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "world.openfoodfacts.org")
        #expect(components.path == "/api/v2/product/3017620422003.json")
        let fields = components.queryItems?.first { $0.name == "fields" }?.value
        #expect(fields == OFFProduct.fields.joined(separator: ","))
        #expect(OFFProduct.fields.contains("nutriments"))
        #expect(OFFProduct.fields.contains("serving_quantity"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Nutrilog/1.2 (https://github.com/memphin/nutrilog)")
        #expect(request.timeoutInterval == 8)
        #expect(request.httpMethod == "GET")
    }

    @Test func `blank contact still gives a valid User-Agent`() {
        let client = OpenFoodFactsHTTPClient(contact: "  ")
        #expect(client.userAgent == "Nutrilog/1.0")
    }

    // MARK: - Responses

    @Test func `found product is returned and mapped`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("nutella_complete"))])
        let client = makeClient(transport)

        let product = try await client.product(barcode: Self.nutella)
        #expect(product.code == Self.nutella)
        #expect(product.productName == "Nutella")

        let draft = try await client.food(barcode: Self.nutella)
        #expect(draft.dataQuality == .complete)
        #expect(draft.nutrients.kcal == 539)
        #expect(transport.requests.count == 2)
    }

    @Test func `string status and numeric code are accepted`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("string_numbers"))])
        let product = try await makeClient(transport).product(barcode: "5449000000996")
        #expect(product.code == "5449000000996")
    }

    @Test func `status 0 with HTTP 200 is notFound`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("status0_not_found"))])
        await #expect(throws: OpenFoodFactsError.notFound) {
            try await makeClient(transport).product(barcode: "3850003123452")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `status 0 with HTTP 404 is notFound`() async throws {
        let transport = try StubTransport([.http(404, Fixture.data("status0_not_found"))])
        await #expect(throws: OpenFoodFactsError.notFound) {
            try await makeClient(transport).product(barcode: "3850003123452")
        }
    }

    @Test func `HTTP 404 without a JSON body is notFound`() async throws {
        let transport = StubTransport([.http(404, Data("<html>Not Found</html>".utf8))])
        await #expect(throws: OpenFoodFactsError.notFound) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
    }

    @Test(arguments: [
        "not json",
        "[]",
        #"{"status": 1}"#,
        #"{"status": 1, "product": "oops"}"#,
        #"{"product": {"code": "3017620422003"}}"#,
    ])
    func `unusable 200 bodies are invalidResponse`(body: String) async {
        let transport = StubTransport([.http(200, Data(body.utf8))])
        await #expect(throws: OpenFoodFactsError.invalidResponse) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `missing product code is filled from the request`() async throws {
        let body = #"{"status": 1, "product": {"product_name": "X"}}"#
        let transport = StubTransport([.http(200, Data(body.utf8))])
        let product = try await makeClient(transport).product(barcode: Self.nutella)
        #expect(product.code == Self.nutella)
    }

    @Test(arguments: ["", "abc", "1234567", "123456789012345", "30176204220 03", "3017620422003/../x"])
    func `invalid barcodes fail without a request`(barcode: String) async {
        let transport = StubTransport([.failure(.badURL)])
        await #expect(throws: OpenFoodFactsError.invalidBarcode) {
            try await makeClient(transport).product(barcode: barcode)
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Retries & errors

    @Test func `timeouts are retried twice with exponential backoff`() async throws {
        let transport = try StubTransport([
            .failure(.timedOut),
            .failure(.timedOut),
            .http(200, Fixture.data("nutella_complete")),
        ])
        let sleeper = SleepRecorder()
        let product = try await makeClient(transport, sleeper: sleeper).product(barcode: Self.nutella)
        #expect(product.productName == "Nutella")
        #expect(transport.requests.count == 3)
        #expect(sleeper.delays == [.milliseconds(500), .milliseconds(1000)])
    }

    @Test func `timeouts on every attempt end as timedOut after 3 requests`() async {
        let transport = StubTransport([.failure(.timedOut)])
        let sleeper = SleepRecorder()
        await #expect(throws: OpenFoodFactsError.timedOut) {
            try await makeClient(transport, sleeper: sleeper).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 3)
        #expect(sleeper.delays.count == 2)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff])
    func `no connection fails at once as offline`(code: URLError.Code) async {
        let transport = StubTransport([.failure(code)])
        let sleeper = SleepRecorder()
        await #expect(throws: OpenFoodFactsError.offline) {
            try await makeClient(transport, sleeper: sleeper).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test(arguments: [URLError.Code.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed])
    func `unreachable host is retried, then offline`(code: URLError.Code) async {
        let transport = StubTransport([.failure(code)])
        await #expect(throws: OpenFoodFactsError.offline) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 3)
    }

    @Test func `HTTP 5xx is retried, then server error`() async {
        let transport = StubTransport([.http(503, Data("Service Unavailable".utf8))])
        await #expect(throws: OpenFoodFactsError.server(status: 503)) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 3)
    }

    @Test func `HTTP 429 is retried and can recover`() async throws {
        let transport = try StubTransport([.http(429, Data()), .http(200, Fixture.data("kras_dorina_hr"))])
        let product = try await makeClient(transport).product(barcode: "3850102000579")
        #expect(product.productNameHR == "Dorina mliječna čokolada")
        #expect(transport.requests.count == 2)
    }

    @Test func `persistent HTTP 429 ends as rateLimited`() async {
        let transport = StubTransport([.http(429, Data())])
        await #expect(throws: OpenFoodFactsError.rateLimited) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
    }

    @Test func `other 4xx fail without retry`() async {
        let transport = StubTransport([.http(403, Data())])
        await #expect(throws: OpenFoodFactsError.server(status: 403)) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `other URL errors fail without retry`() async {
        let transport = StubTransport([.failure(.badServerResponse)])
        await #expect(throws: OpenFoodFactsError.network(.badServerResponse)) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `cancelled request throws CancellationError`() async {
        let transport = StubTransport([.failure(.cancelled)])
        await #expect(throws: CancellationError.self) {
            try await makeClient(transport).product(barcode: Self.nutella)
        }
    }

    @Test func `retry policy doubles the delay`() {
        let policy = OpenFoodFactsHTTPClient.RetryPolicy(maxRetries: 2, baseDelay: .milliseconds(500))
        #expect(policy.delay(beforeRetry: 0) == .milliseconds(500))
        #expect(policy.delay(beforeRetry: 1) == .seconds(1))
        #expect(policy.delay(beforeRetry: 2) == .seconds(2))
    }
}
