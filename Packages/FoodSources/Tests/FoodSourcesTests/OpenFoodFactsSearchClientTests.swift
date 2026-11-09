import Foundation
import Testing
@testable import FoodSources

struct OpenFoodFactsSearchClientTests {
    private static let userAgent = "Nutrilog/1.2 (https://github.com/memphin/nutrilog)"

    private func makeClient(_ transport: StubTransport) -> OpenFoodFactsSearchHTTPClient {
        OpenFoodFactsSearchHTTPClient(userAgent: Self.userAgent, transport: transport)
    }

    // MARK: - Request

    @Test func `request uses v1 full-text search with the fields allowlist, User-Agent and 5 s timeout`() throws {
        let client = OpenFoodFactsSearchHTTPClient(userAgent: Self.userAgent, pageSize: 15)
        let request = client.request(query: "kraš dorina")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "world.openfoodfacts.org")
        #expect(components.path == "/cgi/search.pl")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["search_terms"] == "kraš dorina")
        #expect(items["search_simple"] == "1")
        #expect(items["json"] == "1")
        #expect(items["page_size"] == "15")
        #expect(items["fields"] == OFFProduct.fields.joined(separator: ","))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
        #expect(request.timeoutInterval == 5)
        #expect(request.httpMethod == "GET")
    }

    @Test func `plus in the query is percent-encoded`() throws {
        let request = makeClient(StubTransport([.http(200, Data())])).request(query: "c+ juice")
        let query = try #require(request.url?.query(percentEncoded: true))
        #expect(query.contains("search_terms=c%2B%20juice"))
    }

    @Test func `blank User-Agent falls back to the app name`() {
        #expect(OpenFoodFactsSearchHTTPClient(userAgent: "  ").userAgent == "Nutrilog/1.0")
    }

    @Test func `blank query returns nothing without a request`() async throws {
        let transport = StubTransport([.http(200, Data())])
        let results = try await makeClient(transport).search(query: "   ")
        #expect(results.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Responses

    @Test func `real nutella search maps every hit`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("search_nutella"))])
        let results = try await makeClient(transport).search(query: "nutella")
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.origin == .off })
        let first = try #require(results.first)
        #expect(first.sourceID == "3017620422003")
        #expect(first.barcode == "3017620422003")
        #expect(first.name == "Nutella")
        #expect(first.brand == "Ferrero")
        #expect(first.dataQuality == .complete)
        #expect(isClose(first.nutrients.kcal, 539, tolerance: 1))
        #expect(transport.requests.count == 1)
    }

    @Test func `real Croatian search keeps Croatian names and servings`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("search_dorina"))])
        let results = try await makeClient(transport).search(query: "dorina")
        #expect(results.map(\.sourceID) == ["3850102111961", "3850102128440", "3850102117215", "3850102110711"])
        #expect(results[0].name == "Dorina Mliječna")
        #expect(results[0].brand == "Dorina")
        #expect(results[2].serving?.amount == 20)
        #expect(results.allSatisfy { $0.basis == .per100 })
    }

    @Test func `products without a code or nutrition and non-objects are skipped`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("search_edge_cases"))])
        let results = try await makeClient(transport).search(query: "x")
        #expect(results.map(\.sourceID) == ["3850000000024", "3850000000031", "3850000000048"])
        // Numeric code and string values are read leniently; a blank name is left to the caller.
        #expect(results[0].name == nil)
        #expect(results[0].brand == "PODRAVKA")
        #expect(results[0].nutrients.proteinG == 10.5)
        // Per-serving only, no weight: kept, flagged per serving.
        #expect(results[1].basis == .perServing)
        #expect(results[1].dataQuality == .partialMacros)
        // Energy only.
        #expect(results[2].dataQuality == .energyOnly)
    }

    @Test func `empty result list`() async throws {
        let body = Data(#"{"count": 0, "page": 1, "page_size": 20, "products": [], "skip": 0}"#.utf8)
        let results = try await makeClient(StubTransport([.http(200, body)])).search(query: "zzzz")
        #expect(results.isEmpty)
    }

    @Test(arguments: ["not json", "[]", #"{"count": 3}"#, "<html>busy</html>"])
    func `a 2xx without a products list is invalidResponse`(body: String) async {
        let transport = StubTransport([.http(200, Data(body.utf8))])
        await #expect(throws: OpenFoodFactsError.invalidResponse) {
            try await makeClient(transport).search(query: "nutella")
        }
    }

    // MARK: - Failures (never retried)

    @Test(arguments: [429, 503])
    func `throttling statuses are rateLimited and not retried`(status: Int) async {
        let transport = StubTransport([.http(status, Data("<html>Page temporarily unavailable</html>".utf8))])
        await #expect(throws: OpenFoodFactsError.rateLimited) {
            try await makeClient(transport).search(query: "nutella")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `server error is not retried`() async {
        let transport = StubTransport([.http(500, Data())])
        await #expect(throws: OpenFoodFactsError.server(status: 500)) {
            try await makeClient(transport).search(query: "nutella")
        }
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, OpenFoodFactsError.offline),
        (.networkConnectionLost, .offline),
        (.timedOut, .timedOut),
        (.badURL, .network(.badURL)),
    ])
    func `transport failures map without retrying`(code: URLError.Code, expected: OpenFoodFactsError) async {
        let transport = StubTransport([.failure(code)])
        await #expect(throws: expected) {
            try await makeClient(transport).search(query: "nutella")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `cancelled URL request surfaces as CancellationError`() async {
        let transport = StubTransport([.failure(.cancelled)])
        await #expect(throws: CancellationError.self) {
            try await makeClient(transport).search(query: "nutella")
        }
    }

    @Test func `cancelled task makes no request`() async {
        let transport = StubTransport([.http(200, Data())])
        let client = makeClient(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.search(query: "nutella")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.isEmpty)
    }
}

struct FoodNameCasingTests {
    @Test(arguments: [
        ("CHOCOLATE HAZELNUT SPREAD", "Chocolate Hazelnut Spread"),
        ("MILK WITH COCOA AND SUGAR", "Milk with Cocoa and Sugar"),
        ("THE ORIGINAL BBQ SAUCE", "The Original BBQ Sauce"),
        ("KELLOGG'S FROSTED FLAKES", "Kellogg's Frosted Flakes"),
        ("FERRERO U.S.A., INCORPORATED", "Ferrero U.S.A., Incorporated"),
        ("TREECRISP 2 GO", "Treecrisp 2 Go"),
        ("PEANUT BUTTER-FILLED PRETZELS (BITES)", "Peanut Butter-Filled Pretzels (Bites)"),
        ("ČOKOLADA S LJEŠNJACIMA", "Čokolada S Lješnjacima"),
        ("UHT MILK 3.5%", "UHT Milk 3.5%"),
    ])
    func `all caps names are title-cased`(input: String, expected: String) {
        #expect(FoodNameCasing.titleCasedIfAllCaps(input) == expected)
    }

    @Test(arguments: ["Apples, raw, with skin", "McVitie's Digestive", "Nutella", "iPhone bar", "A", "100 G", ""])
    func `mixed-case and letterless names are left alone`(input: String) {
        #expect(FoodNameCasing.titleCasedIfAllCaps(input) == input)
    }

    @Test func `draft name, local name and brand are display-cased`() {
        let draft = FoodDraft(
            origin: .usda, sourceID: "1", name: "NUTELLA HAZELNUT SPREAD", nameLocal: "Mixed Case",
            brand: "FERRERO", nutrients: .zero,
        ).displayCased
        #expect(draft.name == "Nutella Hazelnut Spread")
        #expect(draft.nameLocal == "Mixed Case")
        #expect(draft.brand == "Ferrero")
    }
}
