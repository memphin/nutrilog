import Foundation
import Testing
@testable import FoodSources

struct OpenFoodFactsSearchClientTests {
    private static let contact = "https://github.com/memphin/vitalion"
    private static let userAgent = "Vitalion/1.2 (https://github.com/memphin/vitalion)"

    private func makeClient(_ transport: StubTransport) -> OpenFoodFactsSearchHTTPClient {
        OpenFoodFactsSearchHTTPClient(contact: Self.contact, appVersion: "1.2", transport: transport)
    }

    // MARK: - Request

    @Test func `request uses Search-a-licious with the fields allowlist, User-Agent and 5 s timeout`() throws {
        let client = OpenFoodFactsSearchHTTPClient(contact: Self.contact, appVersion: "1.2", pageSize: 15)
        let request = try #require(client.request(query: "kraš dorina"))
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "search.openfoodfacts.org")
        #expect(components.path == "/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["q"] == OpenFoodFactsSearchHTTPClient.luceneQuery("kraš dorina"))
        #expect(items["page_size"] == "15")
        #expect(items["fields"] == "code,product_name,product_name_hr,product_name_en,generic_name,brands,quantity")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
        #expect(request.timeoutInterval == 5)
        #expect(request.httpMethod == "GET")
    }

    @Test func `query matches every word in the main name, English name, generic name or brand, with nutrition`() {
        #expect(OpenFoodFactsSearchHTTPClient.luceneQuery("  Dorina  Mliječna ") == """
        (product_name.main:(dorina mliječna) OR product_name.en:(dorina mliječna) OR generic_name.en:(dorina mliječna) \
        OR brands:(dorina mliječna)) AND states_tags:"en:nutrition-facts-completed"
        """)
    }

    @Test func `query syntax typed by the user is dropped`() {
        #expect(OpenFoodFactsSearchHTTPClient.luceneQuery(#"milk" AND (a:b) c+ OR*"#)
            == OpenFoodFactsSearchHTTPClient.luceneQuery("milk and a b c or"))
    }

    @Test(arguments: ["", "   ", "\"(:)*\""])
    func `text without words makes no request`(text: String) async throws {
        let transport = StubTransport([.http(200, Data())])
        #expect(OpenFoodFactsSearchHTTPClient.luceneQuery(text) == nil)
        let results = try await makeClient(transport).search(query: text)
        #expect(results.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func `blank contact falls back to the app name and version`() {
        #expect(OpenFoodFactsSearchHTTPClient(contact: "  ", appVersion: "2.0").userAgent == "Vitalion/2.0")
    }

    // MARK: - Responses

    @Test func `real nutella search lists every hit`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("search_nutella"))])
        let results = try await makeClient(transport).search(query: "nutella")
        #expect(results.count == 4)
        #expect(results.map(\.code) == ["0202416019687", "8000500223321", "80177333", "8000500280706"])
        let second = results[1]
        #expect(second.name == "Nutella B-ready")
        #expect(second.brand == "Nutella")
        #expect(second.quantity == "286,5 g, 15 pièces")
        #expect(second.productURL?.absoluteString == "https://world.openfoodfacts.org/product/8000500223321")
        #expect(results[0].brand == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func `real Croatian search finds products by their main-language name`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("search_dorina"))])
        let results = try await makeClient(transport).search(query: "dorina mliječna")
        #expect(results.map(\.code) == ["3850102501946", "3850102111961", "3850102502189"])
        #expect(results[1].name == "Dorina Mliječna")
        #expect(results[1].brand == "Kraš")
        #expect(results[1].quantity == "80g")
    }

    @Test func `hits without a valid barcode, duplicates and non-objects are skipped`() async throws {
        let body = Data("""
        {"count": 6, "hits": [
          {"code": "3850102111961", "brands": "PODRAVKA", "product_name": " "},
          {"code": "", "product_name": "No code"},
          {"code": "123", "product_name": "Internal code"},
          42,
          {"code": "3850102111961", "product_name": "Again"},
          {"code": "036000291452", "brands": [" ", "Acme"], "quantity": " "}
        ]}
        """.utf8)
        let results = try await makeClient(StubTransport([.http(200, body)])).search(query: "x")
        #expect(results.map(\.code) == ["3850102111961", "0036000291452"]) // UPC-A normalized to EAN-13
        #expect(results[0].name == nil)
        #expect(results[0].brand == "PODRAVKA")
        #expect(results[1].brand == "Acme")
        #expect(results[1].quantity == nil)
    }

    @Test func `all caps names are display-cased`() {
        let hit = OFFSearchHit(code: "1", name: "KRAŠ DORINA", brand: "KRAŠ").displayCased
        #expect(hit.name == "Kraš Dorina")
        #expect(hit.brand == "Kraš")
    }

    @Test func `empty result list`() async throws {
        let body = Data(#"{"hits": [], "count": 0, "page": 1, "page_size": 20}"#.utf8)
        let results = try await makeClient(StubTransport([.http(200, body)])).search(query: "zzzz")
        #expect(results.isEmpty)
    }

    @Test(arguments: ["not json", "[]", #"{"count": 3}"#, "<html>busy</html>"])
    func `a 2xx without a hits list is invalidResponse`(body: String) async {
        let transport = StubTransport([.http(200, Data(body.utf8))])
        await #expect(throws: OpenFoodFactsError.invalidResponse) {
            try await makeClient(transport).search(query: "nutella")
        }
    }

    // MARK: - Failures (never retried)

    @Test func `too many requests (429) is rateLimited and not retried`() async {
        let transport = StubTransport([.http(429, Data())])
        await #expect(throws: OpenFoodFactsError.rateLimited) {
            try await makeClient(transport).search(query: "nutella")
        }
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [500, 503])
    func `server errors are not retried and start no cool-down`(status: Int) async {
        let transport = StubTransport([.http(status, Data("<html>Service unavailable</html>".utf8))])
        let client = makeClient(transport)
        await #expect(throws: OpenFoodFactsError.server(status: status)) {
            try await client.search(query: "nutella")
        }
        #expect(transport.requests.count == 1)
        #expect(client.rateLimitedUntil == nil)
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

struct OpenFoodFactsSearchThrottleTests {
    private func makeClient(_ transport: StubTransport, clock: TestClock, sleeper: SleepRecorder) -> OpenFoodFactsSearchHTTPClient {
        OpenFoodFactsSearchHTTPClient(contact: "x", transport: transport, now: { clock.now }, sleep: sleeper.sleep)
    }

    @Test func `responses are never read from or kept for URLCache`() {
        let request = OpenFoodFactsSearchHTTPClient(contact: "x").request(query: "nutella")
        #expect(request?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func `a 429 starts a 60 s cool-down with no requests`() async throws {
        let clock = TestClock()
        let transport = try StubTransport([.http(429, Data()), .http(200, Fixture.data("search_nutella"))])
        let client = makeClient(transport, clock: clock, sleeper: SleepRecorder())

        await #expect(throws: OpenFoodFactsError.rateLimited) { try await client.search(query: "nutella") }
        let until = try #require(client.rateLimitedUntil)
        #expect(until == clock.now.addingTimeInterval(60))

        clock.advance(by: 59)
        await #expect(throws: OpenFoodFactsError.rateLimited) { try await client.search(query: "nutella") }
        #expect(transport.requests.count == 1)

        clock.advance(by: 2)
        #expect(client.rateLimitedUntil == nil)
        let results = try await client.search(query: "nutella")
        #expect(results.count == 4)
        #expect(transport.requests.count == 2)
    }

    @Test func `a 429 with Retry-After cools down that long`() async throws {
        let clock = TestClock()
        let transport = StubTransport([.http(429, Data(), headers: ["Retry-After": "15"])])
        let client = makeClient(transport, clock: clock, sleeper: SleepRecorder())
        await #expect(throws: OpenFoodFactsError.rateLimited) { try await client.search(query: "nutella") }
        #expect(client.rateLimitedUntil == clock.now.addingTimeInterval(15))
    }

    @Test func `requests are spaced at least 0.5 s apart`() async throws {
        let clock = TestClock()
        let sleeper = SleepRecorder()
        let transport = try StubTransport([.http(200, Fixture.data("search_nutella"))])
        let client = makeClient(transport, clock: clock, sleeper: sleeper)

        _ = try await client.search(query: "nu")
        #expect(sleeper.delays.isEmpty)
        clock.advance(by: 0.2)
        _ = try await client.search(query: "nut")
        #expect(sleeper.delays == [.milliseconds(300)])
        clock.advance(by: 5)
        _ = try await client.search(query: "nute")
        #expect(sleeper.delays == [.milliseconds(300)])
        #expect(transport.requests.count == 3)
    }

    @Test func `searches cancelled while waiting give their slot back`() async throws {
        let clock = TestClock()
        let throttle = OFFSearchThrottle(minimumInterval: .milliseconds(1500))
        let transport = try StubTransport([.http(200, Fixture.data("search_nutella"))])
        let sleeper = SleepRecorder()
        let client = OpenFoodFactsSearchHTTPClient(
            contact: "x", transport: transport, throttle: throttle, now: clock.closure, sleep: sleeper.sleep,
        )
        // Every keystroke cancels the previous search while it waits for its slot.
        let cancelledSleeps = SleepRecorder()
        let cancelling = OpenFoodFactsSearchHTTPClient(
            contact: "x", transport: transport, throttle: throttle, now: clock.closure,
            sleep: { delay in
                try await cancelledSleeps.sleep(delay)
                throw CancellationError()
            },
        )

        _ = try await client.search(query: "n")
        for query in ["nu", "nut", "nute", "nutel", "nutell", "nutella "] {
            clock.advance(by: 0.1)
            await #expect(throws: CancellationError.self) { try await cancelling.search(query: query) }
        }
        #expect(transport.requests.count == 1)
        clock.advance(by: 0.1) // 0.7 s after the only request sent
        _ = try await client.search(query: "nutella")
        #expect(sleeper.delays == [.milliseconds(800)])
        #expect(transport.requests.count == 2)
        // Each abandoned search waited for the same free slot, 1.5 s after the request sent.
        #expect(cancelledSleeps.delays == [1400, 1300, 1200, 1100, 1000, 900].map { .milliseconds($0) })
    }

    @Test func `two waiters for the same slot are still spaced apart`() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let throttle = OFFSearchThrottle(minimumInterval: .milliseconds(1500))
        #expect(throttle.claim(throttle.nextSlot(now: start), now: start) == nil)
        let later = start.addingTimeInterval(0.2)
        let first = throttle.nextSlot(now: later)
        let second = throttle.nextSlot(now: later)
        #expect(first == start.addingTimeInterval(1.5))
        #expect(second == first)
        #expect(throttle.claim(first, now: first) == nil)
        // The second waiter lost the race: it must wait one more interval.
        #expect(throttle.claim(second, now: second) == start.addingTimeInterval(3))
        #expect(throttle.claim(start.addingTimeInterval(3), now: start.addingTimeInterval(3)) == nil)
    }

    @Test func `copies of a client share the throttle`() async throws {
        let clock = TestClock()
        let throttle = OFFSearchThrottle()
        let transport = StubTransport([.http(429, Data())])
        let first = OpenFoodFactsSearchHTTPClient(contact: "a", transport: transport, throttle: throttle, now: { clock.now })
        let second = OpenFoodFactsSearchHTTPClient(contact: "a", transport: transport, throttle: throttle, now: { clock.now })
        await #expect(throws: OpenFoodFactsError.rateLimited) { try await first.search(query: "x") }
        #expect(second.rateLimitedUntil != nil)
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
        ("KFC ORIGINAL RECIPE", "KFC Original Recipe"),
        ("DM BIO OAT FLAKES", "DM Bio Oat Flakes"),
        ("O'REILLY'S IRISH CREAM", "O'Reilly's Irish Cream"),
        ("D'ARBO APRICOT JAM", "D'Arbo Apricot Jam"),
        ("DRY ROASTED PEANUTS", "Dry Roasted Peanuts"),
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
