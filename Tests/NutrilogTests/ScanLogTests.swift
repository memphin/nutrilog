import Core
import FoodLookup
import FoodSources
import Foundation
import Persistence
import Testing
@testable import Nutrilog

/// The scan flow writes the local scan log (backlog #30) that Settings → Barcode resolution reads.
@MainActor
struct ScanLogTests {
    typealias Codes = ScanFlowTests

    func environment(failure: OpenFoodFactsError? = nil) -> (AppEnvironment, StubOpenFoodFactsClient) {
        let client = StubOpenFoodFactsClient(products: [ScanFlowTests.complete, ScanFlowTests.energyOnly], failure: failure)
        let clock = ManualClock()
        return (AppEnvironment.preview(clock: clock.appClock, openFoodFacts: client), client)
    }

    func events(_ env: AppEnvironment) throws -> [ScanEvent] {
        try #require(env.scanLog).events(since: .distantPast)
    }

    @Test func `each resolution is logged with its outcome`() async throws {
        let (env, client) = environment()
        let model = ScanFlowModel(environment: env)

        await model.handle([Codes.nutella]) // OFF network, complete
        model.resumeScanning()
        await model.handle([Codes.partialCode]) // OFF network, energy only
        model.resumeScanning()
        await model.handle([Codes.nutella]) // fresh cache entry
        model.resumeScanning()

        client.setFailure(.offline)
        await model.handle([Codes.unknownCode]) // nothing cached: offline
        model.resumeScanning()

        let logged = try events(env)
        #expect(logged.map(\.outcome) == [.offNetwork, .offNetwork, .offCache, .offline])
        #expect(logged.map(\.barcode) == [Codes.nutella, Codes.partialCode, Codes.nutella, Codes.unknownCode])
        #expect(logged.map(\.dataQuality) == ["complete", "energy_only", "complete", nil])
    }

    @Test func `not found, created, then found locally counts as resolved`() async throws {
        let (env, _) = environment()
        let model = ScanFlowModel(environment: env)

        await model.handle([Codes.unknownCode])
        #expect(model.phase == .notFound(barcode: Codes.unknownCode))
        let saved = try #require(env.foods).save(FoodDetail(
            food: Food(name: "Domaći ajvar", per100: Nutrients(kcal: 80, proteinG: 1.5, carbsG: 8, fatG: 4.5)),
            barcodes: [Codes.unknownCode],
        ))
        model.foodCreated(saved)

        let next = ScanFlowModel(environment: env)
        await next.handle([Codes.unknownCode])
        #expect(next.product?.food.id == saved.food.id)

        #expect(try events(env).map(\.outcome) == [.notFound, .created, .local])
        let stats = try #require(env.scanLog).stats()
        #expect(stats.scanRate == 1)
        #expect(stats.regularRate == 1)
        #expect(stats.excusedMisses == 1)
    }

    @Test func `a food created under another code is not logged as the manual entry`() async throws {
        let (env, _) = environment()
        let model = ScanFlowModel(environment: env)
        await model.handle([Codes.unknownCode])
        let saved = try #require(env.foods).save(FoodDetail(
            food: Food(name: "Something else", per100: Nutrients(kcal: 80, proteinG: 1, carbsG: 8, fatG: 4)),
            barcodes: ["4000417025005"],
        ))
        model.foodCreated(saved)
        #expect(try events(env).map(\.outcome) == [.notFound])
    }

    @Test func `invalid codes and a missing log don't record anything`() async throws {
        let (env, _) = environment()
        let model = ScanFlowModel(environment: env)
        await model.handle(["123"])
        #expect(try events(env).isEmpty)

        // The memberwise init without a log (other tests, previews) still scans.
        let unlogged = ScanFlowModel(lookup: env.barcodeLookup, foods: env.foods, labelPhotos: .temporary())
        await unlogged.handle([Codes.nutella])
        #expect(unlogged.product != nil)
        #expect(try events(env).isEmpty)
    }

    @Test func `offline after a failed retry is logged per attempt`() async throws {
        let (env, client) = environment(failure: .offline)
        let model = ScanFlowModel(environment: env)
        await model.handle([Codes.nutella])
        client.setFailure(nil)
        await model.retry()
        #expect(model.product != nil)
        #expect(try events(env).map(\.outcome) == [.offline, .offNetwork])
    }

    @Test func `a food made in the Foods tab after a miss excuses it`() async throws {
        let (env, _) = environment()
        let model = ScanFlowModel(environment: env)
        await model.handle([Codes.unknownCode])
        model.resumeScanning() // closed the not-found screen without creating the food

        // Later, from the Foods tab: no `created` event is logged.
        let editor = FoodEditorModel(energyUnit: .kcal, barcode: Codes.unknownCode)
        editor.name = "Domaći ajvar"
        editor.energy = "80"
        editor.protein = "1.5"
        editor.carbs = "8"
        editor.fat = "4.5"
        try #require(env.foods).save(#require(editor.makeDetail()))

        await model.handle([Codes.unknownCode])
        #expect(model.product != nil)
        #expect(try events(env).map(\.outcome) == [.notFound, .local])
        let stats = try #require(env.scanLog).stats()
        #expect(stats.excusedMisses == 1)
        #expect(stats.regularRate == 1)
    }

    @Test func `creating the food after an offline failure logs it`() async throws {
        let (env, _) = environment(failure: .offline)
        let model = ScanFlowModel(environment: env)
        await model.handle([Codes.unknownCode])
        #expect(model.phase == .failed(.offline, candidates: [Codes.unknownCode]))
        let saved = try #require(env.foods).save(FoodDetail(
            food: Food(name: "Pita", per100: Nutrients(kcal: 250, proteinG: 8, carbsG: 30, fatG: 10)),
            barcodes: [Codes.unknownCode],
        ))
        model.foodCreated(saved)

        let logged = try events(env)
        #expect(logged.map(\.outcome) == [.offline, .created])
        #expect(logged.map(\.barcode) == [Codes.unknownCode, Codes.unknownCode])
        let stats = try #require(env.scanLog).stats()
        #expect(stats.scanRate == nil) // offline isn't conclusive, `created` isn't a scan
    }

    @Test func `a local hit under a later candidate key is logged under that key`() async throws {
        let (env, client) = environment(failure: .offline)
        let upce = "0012345000065" // the UPC-E reading of 01234565, expanded to EAN-13
        try #require(env.foods).save(FoodDetail(
            food: Food(name: "UPC-E product", per100: Nutrients(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1)),
            barcodes: [upce],
        ))
        let model = ScanFlowModel(environment: env)
        await model.handle(["01234565", upce])
        #expect(model.product != nil)
        #expect(client.requests.isEmpty)
        #expect(try events(env).map(\.barcode) == [upce])
        #expect(try events(env).map(\.outcome) == [.local])
    }

    @Test func `the headline never rounds up to the target`() {
        let en = Locale(identifier: "en_US")
        let rate = 26.0 / 29.0 // 89.66 %
        #expect(BarcodeResolutionView.percent(rate, locale: en) == "89.6%")
        #expect(BarcodeResolutionView.percent(0.8999, locale: en) == "89.9%")
        #expect(BarcodeResolutionView.percent(0.9, locale: en) == "90.0%")
        #expect(BarcodeResolutionView.percent(1, locale: en) == "100.0%")

        var stats = BarcodeResolutionStats(events: [], now: .now)
        stats.regularResolvedScans = 26
        stats.regularCountedScans = 29
        #expect(stats.meetsTarget == false)
        #expect(BarcodeResolutionView.summary(stats).hasPrefix("Below"))
    }

    @Test func `outcome labels and percentages`() {
        #expect(BarcodeResolutionView.percent(nil) == "—")
        #expect(BarcodeResolutionView.qualityLabel("partial_macros") == "partial macros")
        #expect(Set(ScanOutcome.allCases.map(BarcodeResolutionView.label)).count == ScanOutcome.allCases.count)
    }
}
