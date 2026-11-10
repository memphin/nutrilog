import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Synchronization
import Testing
@testable import Vitalion

// MARK: - Stubs

/// A gate that test code opens; waiting on it ignores task cancellation (like a request that is already on the wire).
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Records queries and answers them with `handler`.
private final class QueryRecorder: Sendable {
    private let recorded = Mutex<(queries: [String], cancelled: [String])>(([], []))
    /// What the stub reports as `rateLimitedUntil`.
    let pausedUntil = Mutex<Date?>(nil)
    let handler: @Sendable (String) async throws -> [FoodDraft]

    init(_ handler: @escaping @Sendable (String) async throws -> [FoodDraft]) {
        self.handler = handler
    }

    var queries: [String] {
        recorded.withLock { $0.queries }
    }

    var cancelled: [String] {
        recorded.withLock { $0.cancelled }
    }

    func run(_ query: String) async throws -> [FoodDraft] {
        recorded.withLock { $0.queries.append(query) }
        do {
            return try await handler(query)
        } catch is CancellationError {
            recorded.withLock { $0.cancelled.append(query) }
            throw CancellationError()
        }
    }
}

private struct StubOFFSearch: OpenFoodFactsSearchClient {
    let recorder: QueryRecorder

    var rateLimitedUntil: Date? {
        recorder.pausedUntil.withLock { $0 }
    }

    init(_ handler: @escaping @Sendable (String) async throws -> [FoodDraft] = { _ in [] }) {
        recorder = QueryRecorder(handler)
    }

    func search(query: String) async throws -> [FoodDraft] {
        try await recorder.run(query)
    }
}

/// Throws `.rateLimited` and from then on reports a cool-down, like the real client after HTTP 429/503.
private final class PausingOFF: OpenFoodFactsSearchClient {
    let until: Date
    private let paused = Mutex(false)

    init(until: Date) {
        self.until = until
    }

    var rateLimitedUntil: Date? {
        paused.withLock { $0 } ? until : nil
    }

    func search(query _: String) async throws -> [FoodDraft] {
        paused.withLock { $0 = true }
        throw OpenFoodFactsError.rateLimited
    }
}

private struct StubUSDA: USDAClient {
    var isAvailable = true
    var rateLimitedUntil: Date?
    let recorder: QueryRecorder

    init(
        isAvailable: Bool = true,
        rateLimitedUntil: Date? = nil,
        _ handler: @escaping @Sendable (String) async throws -> [FoodDraft] = { _ in [] },
    ) {
        self.isAvailable = isAvailable
        self.rateLimitedUntil = rateLimitedUntil
        recorder = QueryRecorder(handler)
    }

    func search(query: String) async throws -> [FoodDraft] {
        try await recorder.run(query)
    }
}

private func draft(
    _ origin: FoodDraft.Origin,
    _ id: String,
    _ name: String,
    brand: String? = nil,
    barcode: String? = nil,
    kcal: Double = 100,
) -> FoodDraft {
    FoodDraft(
        origin: origin, sourceID: id, barcode: barcode, name: name, brand: brand,
        nutrients: Nutrients(kcal: kcal, proteinG: 5, carbsG: 10, fatG: 3),
    )
}

// MARK: - Search behaviour

@MainActor
struct OnlineSearchModelTests {
    @Test func `typing is debounced: only the query that stays searches`() async {
        let off = StubOFFSearch { [draft(.off, "1", "Apple juice \($0)")] }
        let usda = StubUSDA { [draft(.usda, "2", "Apples, raw \($0)")] }
        let model = OnlineSearchModel(debounce: .seconds(1)) // long enough for a slow CI runner

        let first = Task { await model.search("ap", offSearch: off, usda: usda) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(off.recorder.queries.isEmpty) // still waiting out the debounce
        #expect(model.offStatus == .loading)
        first.cancel() // SwiftUI cancels the `.task(id:)` when the text changes
        let second = Task { await model.search("apple", offSearch: off, usda: usda) }
        await first.value
        await second.value

        #expect(off.recorder.queries == ["apple"])
        #expect(usda.recorder.queries == ["apple"])
        #expect(model.query == "apple")
        #expect(Set(model.results.map(\.name)) == ["Apple juice apple", "Apples, raw apple"])
    }

    @Test func `a stale query is cancelled in flight and never overwrites newer results`() async {
        let gate = Gate()
        let off = StubOFFSearch { query in
            if query == "slow" {
                try await Task.sleep(for: .seconds(30)) // cancellable request
            }
            return [draft(.off, query, "OFF \(query)")]
        }
        let usda = StubUSDA { query in
            if query == "slow" {
                await gate.wait() // already answered, arrives late, ignores cancellation
            }
            return [draft(.usda, query, "USDA \(query)")]
        }
        let model = OnlineSearchModel(debounce: .zero)

        let stale = Task { await model.search("slow", offSearch: off, usda: usda) }
        #expect(await waitUntil { off.recorder.queries == ["slow"] && usda.recorder.queries == ["slow"] })
        stale.cancel()
        await Task { await model.search("fast", offSearch: off, usda: usda) }.value
        gate.open()
        await stale.value

        #expect(off.recorder.cancelled == ["slow"])
        #expect(model.query == "fast")
        #expect(Set(model.results.map(\.name)) == ["OFF fast", "USDA fast"])
        #expect(model.offStatus == .loaded(count: 1))
        #expect(model.usdaStatus == .loaded(count: 1))
    }

    @Test func `sources run in parallel; one failing leaves the other's results`() async {
        let off = StubOFFSearch { _ in throw OpenFoodFactsError.offline }
        let usda = StubUSDA { _ in [draft(.usda, "1", "Banana, raw"), draft(.usda, "2", "Banana chips")] }
        let model = OnlineSearchModel(debounce: .zero)

        await model.search("banana", offSearch: off, usda: usda)

        #expect(model.offStatus == .offline)
        #expect(model.usdaStatus == .loaded(count: 2))
        #expect(model.results.map(\.name) == ["Banana, raw", "Banana chips"])
        #expect(model.results.allSatisfy { $0.source == .usda })
        #expect(!model.isLoading)
    }

    @Test func `each source's results show as soon as they arrive`() async {
        let gate = Gate()
        let off = StubOFFSearch { _ in
            await gate.wait()
            return [draft(.off, "3850000000017", "Dorina")]
        }
        let usda = StubUSDA { _ in [draft(.usda, "1", "Chocolate, dark")] }
        let model = OnlineSearchModel(debounce: .zero)

        let search = Task { await model.search("chocolate", offSearch: off, usda: usda) }
        #expect(await waitUntil { !model.results.isEmpty })
        #expect(model.results.map(\.name) == ["Chocolate, dark"])
        #expect(model.offStatus == .loading)
        #expect(model.usdaStatus == .loaded(count: 1))

        gate.open()
        await search.value
        // Appended: rows already on screen keep their place.
        #expect(model.results.map(\.name) == ["Chocolate, dark", "Dorina"])
        #expect(model.offStatus == .loaded(count: 1))
    }

    @Test func `USDA is hidden and never asked without an API key`() async {
        let off = StubOFFSearch { _ in [draft(.off, "1", "Nutella")] }
        let usda = StubUSDA(isAvailable: false)
        let model = OnlineSearchModel(debounce: .zero)

        await model.search("nutella", offSearch: off, usda: usda)

        #expect(model.usdaStatus == .hidden)
        #expect(usda.recorder.queries.isEmpty)
        #expect(model.results.map(\.name) == ["Nutella"])

        await model.search("x", offSearch: off, usda: usda) // too short: reset
        #expect(model.usdaStatus == .hidden)
    }

    @Test func `USDA cool-down shows a paused notice without a request`() async {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let off = StubOFFSearch { _ in [draft(.off, "1", "Nutella")] }
        let usda = StubUSDA(rateLimitedUntil: until)
        let model = OnlineSearchModel(debounce: .zero)

        await model.search("nutella", offSearch: off, usda: usda)

        #expect(model.usdaStatus == .paused(until: until))
        #expect(usda.recorder.queries.isEmpty)
        #expect(model.results.count == 1)
        let text = OnlineSourceStatusRow.text(source: .usda, status: model.usdaStatus)
        #expect(text.hasPrefix("USDA paused until \(until.formatted(date: .omitted, time: .shortened))"))
    }

    @Test func `a 429 during the search switches USDA to paused`() async {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let usda = StubUSDA { _ in throw USDAError.rateLimited(until: until) }
        let model = OnlineSearchModel(debounce: .zero)

        await model.search("rice", offSearch: StubOFFSearch(), usda: usda)

        #expect(model.usdaStatus == .paused(until: until))
        #expect(model.offStatus == .loaded(count: 0))
    }

    @Test func `error statuses`() {
        #expect(OnlineSearchModel.status(for: OpenFoodFactsError.rateLimited) == .busy)
        #expect(OnlineSearchModel.status(for: OpenFoodFactsError.server(status: 503)) == .busy)
        #expect(OnlineSearchModel.status(for: USDAError.offline) == .offline)
        #expect(OnlineSearchModel.status(for: USDAError.missingAPIKey) == .hidden)
        if case .failed = OnlineSearchModel.status(for: USDAError.invalidAPIKey) {} else {
            Issue.record("invalid key should be a failure message")
        }
    }

    @Test func `short queries don't go online`() async {
        let off = StubOFFSearch()
        let usda = StubUSDA()
        let model = OnlineSearchModel(debounce: .zero)
        await model.search(" a ", offSearch: off, usda: usda)
        #expect(off.recorder.queries.isEmpty)
        #expect(usda.recorder.queries.isEmpty)
        #expect(model.offStatus == .idle)
        #expect(model.results.isEmpty)
    }

    @Test func `the same product from both sources is listed once`() async {
        let off = StubOFFSearch { _ in [draft(.off, "3017620422003", "Nutella", barcode: "3017620422003")] }
        let usda = StubUSDA { _ in
            [
                draft(.usda, "1", "NUTELLA", barcode: "3017620422003"),
                draft(.usda, "2", "Hazelnut spread"),
            ]
        }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("nutella", offSearch: off, usda: usda)
        #expect(model.results.count == 2)
        #expect(Set(model.results.compactMap(\.draft.barcode)) == ["3017620422003"])
        #expect(model.results.first { $0.draft.barcode != nil }?.source == .off) // OFF wins, whoever came first
    }

    @Test func `duplicate barcodes within one source's answer are listed once`() async {
        let usda = StubUSDA { _ in
            [
                draft(.usda, "1", "Cola", barcode: "5449000000996"),
                draft(.usda, "2", "Cola (other listing)", barcode: "5449000000996"),
            ]
        }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("cola", offSearch: StubOFFSearch(), usda: usda)
        #expect(model.results.map(\.name) == ["Cola"])
        #expect(model.usdaStatus == .loaded(count: 1))
    }

    @Test func `OFF arriving after USDA replaces the USDA row in place`() async {
        let gate = Gate()
        // OFF keeps UPC-A codes as printed (12 digits); FDC barcodes are normalized to EAN-13.
        let off = StubOFFSearch { _ in
            await gate.wait()
            return [draft(.off, "012345678905", "Peanut butter", barcode: "012345678905")]
        }
        let usda = StubUSDA { _ in
            [draft(.usda, "1", "PEANUT BUTTER", barcode: "0012345678905"), draft(.usda, "2", "Peanuts, raw")]
        }
        let model = OnlineSearchModel(debounce: .zero)
        let search = Task { await model.search("peanut", offSearch: off, usda: usda) }
        #expect(await waitUntil { model.results.count == 2 })
        #expect(model.results[0].source == .usda)

        gate.open()
        await search.value
        #expect(model.results.map(\.id) == ["off:012345678905", "usda:2"])
        #expect(model.offStatus == .loaded(count: 1))
        #expect(model.usdaStatus == .loaded(count: 1))
    }

    @Test func `OFF cool-down shows paused and sends nothing; a throttled answer pauses it`() async {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let off = StubOFFSearch()
        off.recorder.pausedUntil.withLock { $0 = until }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("nutella", offSearch: off, usda: StubUSDA(isAvailable: false))
        #expect(model.offStatus == .paused(until: until))
        #expect(off.recorder.queries.isEmpty)
        #expect(!model.showsNoMatches) // the paused row says why there is nothing
        #expect(OnlineSourceStatusRow.text(source: .off, status: model.offStatus).hasPrefix("Open Food Facts paused until"))

        // A throttled answer (HTTP 429/503) starts the client's cool-down: shown as paused too.
        await model.search("nutellas", offSearch: PausingOFF(until: until), usda: StubUSDA(isAvailable: false))
        #expect(model.offStatus == .paused(until: until))
        // A server error without a cool-down is "busy".
        await model.search(
            "nutella b",
            offSearch: StubOFFSearch { _ in throw OpenFoodFactsError.server(status: 502) },
            usda: StubUSDA(isAvailable: false),
        )
        #expect(model.offStatus == .busy)
    }

    @Test func `cached answers are shown even while a source is paused`() async {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let off = StubOFFSearch { [draft(.off, "3017620422003", "OFF \($0)")] }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("rice", offSearch: off, usda: StubUSDA { [draft(.usda, "1", "Rice \($0)")] })
        await model.search("rice", offSearch: off, usda: StubUSDA(rateLimitedUntil: until))
        #expect(model.usdaStatus == .loaded(count: 1))
        #expect(Set(model.results.map(\.name)) == ["OFF rice", "Rice rice"])
    }

    @Test func `no-matches state only when a source answered`() async {
        let model = OnlineSearchModel(debounce: .zero)
        await model.search(
            "zzz",
            offSearch: StubOFFSearch { _ in throw OpenFoodFactsError.offline },
            usda: StubUSDA { _ in throw USDAError.timedOut },
        )
        #expect(!model.showsNoMatches)
        await model.search("zzzz", offSearch: StubOFFSearch(), usda: StubUSDA { _ in throw USDAError.timedOut })
        #expect(model.showsNoMatches)
    }

    @Test func `an announcement tells VoiceOver when each source answers or fails`() async {
        let heard = Mutex<[String]>([])
        let model = OnlineSearchModel(debounce: .zero, announce: { text in heard.withLock { $0.append(text) } })
        await model.search(
            "banana",
            offSearch: StubOFFSearch { _ in throw OpenFoodFactsError.offline },
            usda: StubUSDA { _ in [draft(.usda, "1", "Banana")] },
        )
        #expect(Set(heard.withLock { $0 }) == ["Open Food Facts: offline", "1 result from USDA"])
    }

    @Test func `repeated queries are answered from the session cache`() async {
        let off = StubOFFSearch { [draft(.off, $0, "OFF \($0)")] }
        let usda = StubUSDA { [draft(.usda, $0, "USDA \($0)")] }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("milk", offSearch: off, usda: usda)
        await model.search("milka", offSearch: off, usda: usda)
        await model.search("Milk ", offSearch: off, usda: usda)
        #expect(off.recorder.queries == ["milk", "milka"])
        #expect(usda.recorder.queries == ["milk", "milka"])
        #expect(model.results.count == 2)
    }

    @Test func `branded ALL CAPS names are title-cased for display`() {
        let result = OnlineFoodResult(draft(.usda, "1", "CHOCOLATE HAZELNUT SPREAD WITH COCOA", brand: "FERRERO U.S.A., INCORPORATED"))
        #expect(result.name == "Chocolate Hazelnut Spread with Cocoa")
        #expect(result.brand == "Ferrero U.S.A., Incorporated")
        #expect(OnlineFoodResult(draft(.usda, "2", "Apples, raw, with skin")).name == "Apples, raw, with skin")
    }
}

// MARK: - Selecting a result

@MainActor
struct OnlineSelectionTests {
    @Test func `selecting a result stores a local copy that local search finds`() throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        let search = try #require(env.search)
        let model = OnlineSearchModel()
        let result = OnlineFoodResult(draft(.usda, "2345678", "ZDENKA CHEESE TRIANGLES", brand: "VINDIJA", kcal: 260))

        guard case let .open(detail) = try model.select(result, in: foods) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(detail.food.source == .usda)
        #expect(detail.food.sourceID == "2345678")
        #expect(detail.food.name == "Zdenka Cheese Triangles")
        #expect(detail.food.brand == "Vindija")
        #expect(detail.food.per100.kcal == 260)

        let local = try search.search("zdenka")
        #expect(local.first?.id == "food:\(detail.food.id)")
        #expect(local.first?.source == .usda)

        // Idempotent: picking it again reuses the copy.
        guard case let .open(again) = try model.select(result, in: foods) else {
            Issue.record("expected the food to open")
            return
        }
        #expect(again.food.id == detail.food.id)
    }

    @Test func `a per-serving-only result asks for the serving weight first`() throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        var bar = draft(.off, "3850000000031", "Protein bar", barcode: "3850000000031", kcal: 210)
        bar.basis = .perServing
        bar.servingDescription = "1 bar"

        guard case let .askServingWeight(pending) = try OnlineSearchModel().select(OnlineFoodResult(bar), in: foods) else {
            Issue.record("expected the serving-weight prompt")
            return
        }
        #expect(pending.detail.isPerServingPlaceholder)

        // Same conversion as the scan flow; quality follows the stored copy (nothing stored as 0 → complete).
        let converted = try pending.detail.convertingPerServingPlaceholder(servingWeight: 40)
        let saved = try foods.save(converted)
        #expect(!saved.isPerServingPlaceholder)
        #expect(saved.food.per100.kcal == 525) // 210 kcal per 40 g bar
        #expect(saved.food.dataQuality == .complete)
        #expect(saved.food.notes == nil)
        #expect(saved.servings.first { $0.id == saved.food.defaultServingID }?.grams == 40)
        #expect(saved.food.id == pending.detail.food.id)

        // Picked again later: the converted copy opens directly.
        guard case .open = try OnlineSearchModel().select(OnlineFoodResult(bar), in: foods) else {
            Issue.record("expected the converted food to open")
            return
        }
    }

    @Test func `a skipped serving weight still logs one serving correctly`() throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        let diary = try #require(env.diary)
        var bar = draft(.off, "3850000000048", "Energy bar", barcode: "3850000000048", kcal: 210)
        bar.basis = .perServing
        bar.servingDescription = "1 bar"
        guard case let .askServingWeight(pending) = try OnlineSearchModel().select(OnlineFoodResult(bar), in: foods) else {
            Issue.record("expected the serving-weight prompt")
            return
        }

        // "Skip" opens the quantity sheet with the placeholder: servings only, 1 serving prefilled.
        let detail = pending.detail
        #expect(!QuantitySheet.offersBaseUnit(detail))
        let serving = try #require(detail.servings.first { $0.id == detail.food.defaultServingID })
        let initial = QuantitySheet.initialLogQuantity(detail)
        #expect(initial.quantity == .servings(count: 1, serving: serving.size))
        #expect(QuantitySheet.quantity(amountText: "100", unitChoice: "base", detail: detail) == nil)

        let entry = try diary.log(
            food: detail.food, quantity: initial.quantity, servingID: serving.id,
            slotID: "breakfast", day: env.today,
        )
        #expect(entry.nutrients.kcal == 210)
        #expect(entry.nutrients.proteinG == 5)
        #expect(entry.servingLabel?.contains("1 bar") == true)
    }

    @Test func `the prompt's conversion rejects implausible weights`() {
        var gummy = draft(.off, "2", "Gummies", kcal: 60)
        gummy.basis = .perServing
        gummy.nutrients = Nutrients(kcal: 60, proteinG: 0, carbsG: 30, fatG: 0)
        let detail = FoodDetail(draft: gummy)
        #expect(throws: ServingWeightError.notPositive) { try detail.convertingPerServingPlaceholder(servingWeight: 0) }
        // 30 g of carbs in a 20 g serving = 150 g per 100 g, though only 300 kcal per 100.
        #expect(throws: ServingWeightError.implausibleMacros(gramsPer100: 150)) {
            try detail.convertingPerServingPlaceholder(servingWeight: 20)
        }
    }

    @Test func `OFF rows link to the product page; USDA rows don't`() {
        var off = draft(.off, "3017620422003", "Nutella")
        off.productURL = URL(string: "https://world.openfoodfacts.org/product/3017620422003")
        var usda = draft(.usda, "1", "Nutella")
        usda.productURL = URL(string: "https://fdc.nal.usda.gov/food-details/1")
        #expect(OnlineFoodResult(off).offProductURL?.absoluteString == "https://world.openfoodfacts.org/product/3017620422003")
        #expect(OnlineFoodResult(usda).offProductURL == nil)
    }
}

struct NetworkInfoTests {
    @Test func `network screen lists every request the app makes`() {
        let paths = NetworkInfoView.hosts.flatMap { host in host.requests.map { host.host + $0.path } }
        #expect(paths == [
            "world.openfoodfacts.org/api/v2/product/{barcode}.json",
            "world.openfoodfacts.org/cgi/search.pl",
            "images.openfoodfacts.org/images/products/…",
            "api.nal.usda.gov/fdc/v1/foods/search",
        ])
    }

    @Test func `network screen covers the hosts of product images`() throws {
        // What OFF returns in `image_front_small_url` and the product card loads (AsyncImage).
        let product = OFFProduct(
            code: "3017620422003",
            productName: "Nutella",
            imageFrontSmallURL: "https://images.openfoodfacts.org/images/products/301/762/042/2003/front_en.633.200.jpg",
        )
        let imageURL = try #require(OFFFoodMapper.map(product).imageURL)
        let host = try #require(imageURL.host())
        #expect(NetworkInfoView.hosts.map(\.host).contains(host))
        let productURL = try #require(OFFFoodMapper.map(product).productURL?.host())
        #expect(NetworkInfoView.hosts.map(\.host).contains(productURL))
    }
}
