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

    @Test func `outcome labels and percentages`() {
        #expect(BarcodeResolutionView.percent(nil) == "—")
        #expect(BarcodeResolutionView.percent(0.9).hasPrefix("90"))
        #expect(BarcodeResolutionView.qualityLabel("partial_macros") == "partial macros")
        #expect(Set(ScanOutcome.allCases.map(BarcodeResolutionView.label)).count == ScanOutcome.allCases.count)
    }
}
