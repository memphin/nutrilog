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
private final class QueryRecorder<Value: Sendable>: Sendable {
    private let recorded = Mutex<(queries: [String], cancelled: [String])>(([], []))
    /// What the stub reports as `rateLimitedUntil`.
    let pausedUntil = Mutex<Date?>(nil)
    /// The food name language each Open Food Facts search was asked for.
    let languages = Mutex<[FoodNameLanguage]>([])
    let handler: @Sendable (String) async throws -> [Value]

    init(_ handler: @escaping @Sendable (String) async throws -> [Value]) {
        self.handler = handler
    }

    var queries: [String] {
        recorded.withLock { $0.queries }
    }

    var cancelled: [String] {
        recorded.withLock { $0.cancelled }
    }

    func run(_ query: String) async throws -> [Value] {
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
    let recorder: QueryRecorder<OFFSearchHit>

    /// The food name language of every search, in order.
    var languages: [FoodNameLanguage] {
        recorder.languages.withLock { $0 }
    }

    var rateLimitedUntil: Date? {
        recorder.pausedUntil.withLock { $0 }
    }

    init(_ handler: @escaping @Sendable (String) async throws -> [OFFSearchHit] = { _ in [] }) {
        recorder = QueryRecorder(handler)
    }

    func search(query: String, nameLanguage: FoodNameLanguage) async throws -> [OFFSearchHit] {
        recorder.languages.withLock { $0.append(nameLanguage) }
        return try await recorder.run(query)
    }
}

private extension OnlineSearchModel {
    /// English food names, for tests that don't care about the food name language.
    func search(_ text: String, offSearch: any OpenFoodFactsSearchClient, usda: any USDAClient) async {
        await search(text, offSearch: offSearch, usda: usda, nameLanguage: .english)
    }
}

/// Throws `.rateLimited` and from then on reports a cool-down, like the real client after HTTP 429.
private final class PausingOFF: OpenFoodFactsSearchClient {
    let until: Date
    private let paused = Mutex(false)

    init(until: Date) {
        self.until = until
    }

    var rateLimitedUntil: Date? {
        paused.withLock { $0 } ? until : nil
    }

    func search(query _: String, nameLanguage _: FoodNameLanguage) async throws -> [OFFSearchHit] {
        paused.withLock { $0 = true }
        throw OpenFoodFactsError.rateLimited
    }
}

private struct StubUSDA: USDAClient {
    var isAvailable = true
    var rateLimitedUntil: Date?
    let recorder: QueryRecorder<FoodDraft>

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

private func hit(_ code: String, _ name: String, brand: String? = nil, quantity: String? = nil) -> OFFSearchHit {
    OFFSearchHit(code: code, name: name, brand: brand, quantity: quantity)
}

// MARK: - Search behaviour

@MainActor
struct OnlineSearchModelTests {
    @Test func `typing is debounced: only the query that stays searches`() async {
        let off = StubOFFSearch { [hit("1", "Apple juice \($0)")] }
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
            return [hit(query, "OFF \(query)")]
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

    @Test func `open food facts is searched in the food name language`() async {
        let off = StubOFFSearch { _ in [hit("3850104012341", "Vegeta dodatak jelima")] }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("vegeta", offSearch: off, usda: StubUSDA(isAvailable: false), nameLanguage: .croatian)
        #expect(off.languages == [.croatian])
    }

    @Test func `each source's results show as soon as they arrive`() async {
        let gate = Gate()
        let off = StubOFFSearch { _ in
            await gate.wait()
            return [hit("3850000000017", "Dorina")]
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
        let off = StubOFFSearch { _ in [hit("1", "Nutella")] }
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
        let off = StubOFFSearch { _ in [hit("1", "Nutella")] }
        let usda = StubUSDA(rateLimitedUntil: until)
        let model = OnlineSearchModel(debounce: .zero)

        await model.search("nutella", offSearch: off, usda: usda)

        #expect(model.usdaStatus == .paused(until: until))
        #expect(usda.recorder.queries.isEmpty)
        #expect(model.results.count == 1)
        let text = OnlineSourceStatusRow.text(source: .usda, status: model.usdaStatus, now: until.addingTimeInterval(-42))
        #expect(text == "USDA is rate-limited. Retrying in 42 seconds.")
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

    @Test func `a result without energy shows a dash, not 0 kcal`() {
        let missing = FoodDraft(
            origin: .off, sourceID: "1", name: "Mystery bar", nutrients: Nutrients(kcal: 0, proteinG: 5, carbsG: 50, fatG: 10),
            missingNutrients: [.energy],
        )
        #expect(OnlineFoodRow.energyText(missing, unit: .kcal) == nil)
        let known = FoodDraft(origin: .off, sourceID: "2", name: "Water", nutrients: Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0))
        #expect(OnlineFoodRow.energyText(known, unit: .kcal) == EnergyUnit.kcal.format(0)) // a real 0 stays 0
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
        let off = StubOFFSearch { _ in [hit("3017620422003", "Nutella")] }
        let usda = StubUSDA { _ in
            [
                draft(.usda, "1", "NUTELLA", barcode: "3017620422003"),
                draft(.usda, "2", "Hazelnut spread"),
            ]
        }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("nutella", offSearch: off, usda: usda)
        #expect(model.results.count == 2)
        #expect(model.results.compactMap(\.barcodeKey) == ["3017620422003"])
        #expect(model.results.first { $0.barcodeKey == "3017620422003" }?.source == .off) // OFF wins, whoever came first
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
        let off = StubOFFSearch { _ in
            await gate.wait()
            return [hit("0012345678905", "Peanut butter")]
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
        #expect(model.results.map(\.id) == ["off:0012345678905", "usda:2"])
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
        #expect(OnlineSourceStatusRow.text(source: .off, status: model.offStatus).hasPrefix("Open Food Facts is rate-limited"))

        // A throttled answer (HTTP 429) starts the client's cool-down: shown as paused too.
        await model.search("nutellas", offSearch: PausingOFF(until: until), usda: StubUSDA(isAvailable: false))
        #expect(model.offStatus == .paused(until: until))
        // A server error without a cool-down is "busy" (and retried; instantly here).
        let retrying = OnlineSearchModel(debounce: .zero, sleep: { _ in })
        await retrying.search(
            "nutella b",
            offSearch: StubOFFSearch { _ in throw OpenFoodFactsError.server(status: 502) },
            usda: StubUSDA(isAvailable: false),
        )
        #expect(retrying.offStatus == .busy)
    }

    @Test func `cached answers are shown even while a source is paused`() async {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let off = StubOFFSearch { [hit("3017620422003", "OFF \($0)")] }
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
        let off = StubOFFSearch { [hit($0, "OFF \($0)")] }
        let usda = StubUSDA { [draft(.usda, $0, "USDA \($0)")] }
        let model = OnlineSearchModel(debounce: .zero)
        await model.search("milk", offSearch: off, usda: usda)
        await model.search("milka", offSearch: off, usda: usda)
        await model.search("Milk ", offSearch: off, usda: usda)
        #expect(off.recorder.queries == ["milk", "milka"])
        #expect(usda.recorder.queries == ["milk", "milka"])
        #expect(model.results.count == 2)
    }

    @Test func `a rate-limited source is searched again when its pause ends`() async {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let off = StubOFFSearch { [hit("3017620422003", "OFF \($0)")] }
        off.recorder.pausedUntil.withLock { $0 = start.addingTimeInterval(42) }
        let waits = Mutex<[Duration]>([])
        let model = OnlineSearchModel(
            debounce: .zero,
            sleep: { delay in
                waits.withLock { $0.append(delay) }
                if delay > .zero {
                    off.recorder.pausedUntil.withLock { $0 = nil } // the cool-down is over
                }
            },
            now: { start },
        )
        await model.search("nutella", offSearch: off, usda: StubUSDA(isAvailable: false))
        #expect(waits.withLock { $0 } == [.zero, .milliseconds(42100)])
        #expect(off.recorder.queries == ["nutella"])
        #expect(model.offStatus == .loaded(count: 1))
        #expect(model.results.map(\.name) == ["OFF nutella"])
    }

    @Test func `automatic retries stop after a few attempts`() async {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let waits = Mutex<[Duration]>([])
        let model = OnlineSearchModel(debounce: .zero, sleep: { delay in waits.withLock { $0.append(delay) } }, now: { start })
        let off = StubOFFSearch { _ in throw OpenFoodFactsError.server(status: 503) }
        await model.search("nutella", offSearch: off, usda: StubUSDA(isAvailable: false))
        #expect(off.recorder.queries.count == 1 + OnlineSearchModel.maxAutomaticRetries)
        #expect(waits.withLock { $0 }.filter { $0 > .zero } == Array(repeating: .milliseconds(5100), count: 3))
        #expect(model.offStatus == .busy)
    }

    @Test func `pause text counts down`() {
        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(OnlineSourceStatusRow.retryText(until: until, now: until.addingTimeInterval(-1)) == "in 1 second")
        #expect(OnlineSourceStatusRow.retryText(until: until, now: until.addingTimeInterval(-3000)) == "in 50 minutes")
        #expect(OnlineSourceStatusRow.retryText(until: until, now: until) == "now")
    }

    @Test func `rows from Open Food Facts show the package size instead of energy`() {
        let result = OnlineFoodResult(hit("3850102111961", "DORINA MLIJEČNA", brand: "KRAŠ", quantity: "80g"))
        #expect(result.draft == nil)
        #expect(result.name == "Dorina Mliječna")
        #expect(result.brand == "Kraš")
        #expect(result.id == "off:3850102111961")
        #expect(result.source == .off)
    }

    @Test func `branded ALL CAPS names are title-cased for display`() {
        let result = OnlineFoodResult(draft(.usda, "1", "CHOCOLATE HAZELNUT SPREAD WITH COCOA", brand: "FERRERO U.S.A., INCORPORATED"))
        #expect(result.name == "Chocolate Hazelnut Spread with Cocoa")
        #expect(result.brand == "Ferrero U.S.A., Incorporated")
        #expect(OnlineFoodResult(draft(.usda, "2", "Apples, raw, with skin")).name == "Apples, raw, with skin")
    }
}
