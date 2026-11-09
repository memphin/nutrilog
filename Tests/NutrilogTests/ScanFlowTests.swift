import Core
import FoodLookup
import FoodSources
import Foundation
import ImageIO
import Persistence
import Testing
import UIKit
@testable import Nutrilog

/// Scan flow (backlog #20) at the model level, with a stub Open Food Facts client (the simulator has no camera).
@MainActor
struct ScanFlowTests {
    static let nutella = "3017620422003"
    static let partialCode = "4006381333931"
    static let perServingCode = "8712345678906"
    static let unknownCode = "5901234123457"
    static let perServingEnergyOnlyCode = "4000417025005"

    static let complete = OFFProduct(
        code: nutella,
        productName: "Nutella",
        brands: "Ferrero",
        servingSize: "15 g",
        servingQuantity: 15,
        nutriments: ["energy-kcal_100g": 539, "proteins_100g": 6.3, "carbohydrates_100g": 57.5, "fat_100g": 30.9],
        nutriscoreGrade: "e",
        imageFrontSmallURL: "https://images.openfoodfacts.org/nutella.jpg",
    )

    /// Energy only: protein, carbs and fat missing.
    static let energyOnly = OFFProduct(
        code: partialCode,
        productName: "Mystery bar",
        nutriments: ["energy-kcal_100g": 450],
    )

    /// Values per serving ("1 shot") with no serving weight.
    static let perServing = OFFProduct(
        code: perServingCode,
        productName: "Energy Shot",
        servingSize: "1 shot",
        nutritionDataPer: "serving",
        nutriments: ["energy-kcal_serving": 12, "proteins_serving": 0, "carbohydrates_serving": 2.7, "fat_serving": 0],
    )

    /// Per serving ("1 bar") with only the energy known.
    static let perServingEnergyOnly = OFFProduct(
        code: perServingEnergyOnlyCode,
        productName: "Protein bar",
        servingSize: "1 bar",
        nutritionDataPer: "serving",
        nutriments: ["energy-kcal_serving": 150],
    )

    @MainActor
    struct Harness {
        let env: AppEnvironment
        let client: StubOpenFoodFactsClient
        let model: ScanFlowModel

        var foods: FoodRepository {
            env.foods!
        }

        /// A fresh scanner session on the same database (what reopening the scanner does).
        func newSession() -> ScanFlowModel {
            ScanFlowModel(environment: env)
        }
    }

    func harness(
        products: [OFFProduct] = [complete, energyOnly, perServing, perServingEnergyOnly],
        failure: OpenFoodFactsError? = nil,
    ) -> Harness {
        let client = StubOpenFoodFactsClient(products: products, failure: failure)
        let env = AppEnvironment.preview(clock: ManualClock().appClock, openFoodFacts: client)
        return Harness(env: env, client: client, model: ScanFlowModel(environment: env))
    }

    func found(_ model: ScanFlowModel) throws -> ScannedProduct {
        try #require(model.product)
    }

    // MARK: -

    @Test func `environment wires the OFF client into the barcode lookup`() async throws {
        let h = harness()
        #expect(h.env.openFoodFacts is StubOpenFoodFactsClient)
        let result = try await #require(h.env.barcodeLookup).resolve(Self.nutella)
        guard case .remote = result else {
            Issue.record("expected a remote product, got \(result)")
            return
        }
        #expect(h.client.requests == [Self.nutella])
    }

    @Test func `live config gives the OFF client a contact`() {
        let config = AppConfig(bundle: .main)
        #expect(!config.offContact.isEmpty)
        #expect(!AppConfig(usdaAPIKey: nil).offContact.isEmpty)
    }

    @Test func `local hit goes straight to quantity without the network`() async throws {
        let h = harness(failure: .offline)
        let saved = try h.foods.save(FoodDetail(
            food: Food(name: "Ajvar", per100: Nutrients(kcal: 80, proteinG: 1.5, carbsG: 8, fatG: 4.5)),
            barcodes: [Self.unknownCode],
        ))

        await h.model.handle([Self.unknownCode])
        let product = try found(h.model)
        #expect(product.isSaved)
        #expect(product.remote == nil)
        #expect(!product.needsCompletion)
        #expect(h.client.requests.isEmpty)

        let detail = try h.model.foodForLogging()
        #expect(detail.food.id == saved.food.id)
    }

    @Test func `remote product is saved with saveRemoteCopy, then logged`() async throws {
        let h = harness()
        await h.model.handle([Self.nutella])
        let product = try found(h.model)
        #expect(!product.isSaved)
        #expect(product.food.name == "Nutella")
        #expect(product.food.brand == "Ferrero")
        #expect(product.nutriscore == "E")
        #expect(product.imageURL?.absoluteString == "https://images.openfoodfacts.org/nutella.jpg")
        #expect(product.per100?.kcal == 539)
        #expect(product.serving?.amount == 15)
        #expect(!product.needsCompletion)
        #expect(!product.isStale)
        #expect(try h.foods.food(barcodes: [Self.nutella]) == nil) // not saved by just looking

        let detail = try h.model.foodForLogging()
        #expect(detail.food.source == .off)
        #expect(detail.barcodes == [Self.nutella])
        #expect(try h.foods.food(barcodes: [Self.nutella])?.food.id == detail.food.id)
        // Idempotent: logging again doesn't create a second copy.
        #expect(try h.model.foodForLogging().food.id == detail.food.id)

        // What the quantity sheet does on "Log".
        let entry = try #require(h.env.diary).log(
            food: detail.food, quantity: .base(30), slotID: "breakfast", day: h.env.today,
        )
        #expect(entry.foodID == detail.food.id)
        #expect(h.model.didLog(detail) == .close)
        #expect(h.model.loggedCount == 1)
    }

    @Test func `not found prefills the editor and the next scan resolves locally offline`() async throws {
        let h = harness()
        await h.model.handle([Self.unknownCode])
        #expect(h.model.phase == .notFound(barcode: Self.unknownCode))
        let barcode = try #require(h.model.barcodeForNewFood)

        // The Create Food form opened from the not-found screen.
        let editor = FoodEditorModel(energyUnit: .kcal, barcode: barcode)
        #expect(editor.barcodes == [Self.unknownCode])
        editor.name = "Domaći ajvar"
        editor.energy = "80"
        editor.protein = "1.5"
        editor.carbs = "8"
        editor.fat = "4.5"
        let saved = try h.foods.save(#require(editor.makeDetail()))
        #expect(saved.barcodes == [Self.unknownCode])
        h.model.foodCreated(saved)
        #expect(try found(h.model).food.id == saved.food.id)

        // Next scan, no network at all: found in the local database without asking OFF.
        h.client.setFailure(.offline)
        let requestsBefore = h.client.requests.count
        let next = h.newSession()
        await next.handle([Self.unknownCode])
        let product = try found(next)
        #expect(product.food.id == saved.food.id)
        #expect(product.isSaved)
        #expect(h.client.requests.count == requestsBefore)
    }

    @Test func `label photo is stored in the container under the new food's id`() async throws {
        let h = harness()
        await h.model.handle([Self.unknownCode])
        let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        h.model.pendingLabelPhoto = photo

        let saved = try h.foods.save(FoodDetail(
            food: Food(name: "Pita", per100: Nutrients(kcal: 250, proteinG: 8, carbsG: 30, fatG: 10)),
            barcodes: [Self.unknownCode],
        ))
        h.model.foodCreated(saved)
        #expect(h.model.pendingLabelPhoto == nil)
        #expect(h.env.labelPhotos.load(foodID: saved.food.id) == photo)
        #expect(h.env.labelPhotos.url(foodID: saved.food.id).lastPathComponent == "\(saved.food.id).jpg")
        try h.env.labelPhotos.delete(foodID: saved.food.id)
        #expect(!h.env.labelPhotos.hasPhoto(foodID: saved.food.id))
    }

    @Test func `offline shows retry and manual creation`() async throws {
        let h = harness(failure: .offline)
        await h.model.handle([Self.nutella])
        #expect(h.model.phase == .failed(.offline, candidates: [Self.nutella]))
        #expect(h.model.showsResult)
        #expect(h.model.barcodeForNewFood == Self.nutella)

        // Back online: retry finds the product.
        h.client.setFailure(nil)
        await h.model.retry()
        #expect(try found(h.model).food.name == "Nutella")
    }

    @Test func `OFF errors other than offline are reported as unavailable`() async {
        let h = harness(failure: .timedOut)
        await h.model.handle([Self.nutella])
        #expect(h.model.phase == .failed(.unavailable, candidates: [Self.nutella]))
    }

    @Test func `stale cache is flagged when OFF can't be reached`() async throws {
        let clock = ManualClock()
        let client = StubOpenFoodFactsClient(products: [Self.complete])
        let env = AppEnvironment.preview(clock: clock.appClock, openFoodFacts: client)
        let model = ScanFlowModel(environment: env)
        await model.handle([Self.nutella]) // cached now
        model.resumeScanning()

        clock.advance(hours: 31 * 24) // past the 30-day product TTL
        client.setFailure(.offline)
        await model.handle([Self.nutella])
        let product = try found(model)
        #expect(product.isStale)
    }

    @Test func `codes that aren't product barcodes keep the camera running`() async {
        let h = harness()
        await h.model.handle([])
        #expect(h.model.phase == .scanning)
        #expect(h.model.notice != nil)
    }

    @Test func `complete nutrition updates the local copy`() async throws {
        let h = harness()
        await h.model.handle([Self.partialCode])
        let product = try found(h.model)
        #expect(product.food.dataQuality == .energyOnly)
        #expect(product.needsCompletion)
        #expect(product.missing == [.protein, .carbs, .fat])

        let request = try h.model.foodForCompletingNutrition()
        #expect(try h.foods.food(barcodes: [Self.partialCode])?.food.id == request.detail.food.id) // saved first

        // The editor opened in complete-nutrition mode: missing values start empty.
        let editor = FoodEditorModel(energyUnit: .kcal, editing: request.detail, completing: request.missing)
        #expect(editor.energy == "450")
        #expect(editor.protein.isEmpty)
        #expect(!editor.canSave)
        editor.protein = "5"
        editor.carbs = "60"
        editor.fat = "20"
        let saved = try h.foods.save(#require(editor.makeDetail()))
        h.model.nutritionCompleted(saved)

        let stored = try #require(try h.foods.detail(id: request.detail.food.id))
        #expect(stored.food.dataQuality == .complete)
        #expect(stored.food.proteinG100 == 5)
        #expect(stored.food.source == .off)
        #expect(stored.barcodes == [Self.partialCode])
        let updated = try found(h.model)
        #expect(!updated.needsCompletion)
        #expect(try h.model.foodForLogging().food.id == stored.food.id)
    }

    @Test func `partial local food infers the missing values`() {
        var food = Food(name: "x", per100: Nutrients(kcal: 100, proteinG: 0, carbsG: 20, fatG: 0), dataQuality: .partialMacros)
        #expect(ScannedProduct.inferredMissing(food) == [.protein, .fat])
        food.dataQuality = .complete
        #expect(ScannedProduct.inferredMissing(food).isEmpty)
    }

    @Test func `continuous mode counts logs and returns to the camera`() async throws {
        let h = harness()
        h.model.keepScanning = true
        for code in [Self.nutella, Self.partialCode] {
            await h.model.handle([code])
            let detail = try h.model.foodForLogging()
            #expect(h.model.didLog(detail) == .keepScanning)
            #expect(h.model.phase == .scanning)
        }
        #expect(h.model.loggedCount == 2)
        #expect(h.model.sessionLog.map(\.name) == ["Nutella · Ferrero", "Mystery bar"])

        h.model.keepScanning = false
        await h.model.handle([Self.nutella])
        #expect(try h.model.didLog(h.model.foodForLogging()) == .close)
        #expect(h.model.loggedCount == 3)
    }

    @Test func `scans are ignored while a card is open`() async throws {
        let h = harness()
        await h.model.handle([Self.nutella])
        await h.model.handle([Self.partialCode])
        #expect(try found(h.model).food.name == "Nutella")
        #expect(h.client.requests == [Self.nutella])
    }

    @Test func `per-serving placeholder asks for the serving weight and converts`() async throws {
        let h = harness()
        await h.model.handle([Self.perServingCode])
        let product = try found(h.model)
        #expect(product.needsServingWeight)
        #expect(product.per100 == nil) // no per-100 table: the values are per serving
        #expect(product.serving?.label == "1 shot")
        #expect(product.serving?.amount == nil)
        #expect(product.serving?.nutrients.kcal == 12)
        #expect(!product.needsCompletion)

        let saved = try h.model.setServingWeight(60)
        #expect(!saved.isPerServingPlaceholder)
        #expect(!saved.food.perServingOnly)
        #expect(saved.food.dataQuality == .complete)
        #expect(saved.food.notes == nil)
        #expect(abs(saved.food.kcal100 - 20) < 1e-9) // 12 kcal per 60 ml
        #expect(abs(saved.food.carbsG100 - 4.5) < 1e-9)
        let serving = try #require(saved.servings.first { $0.id == saved.food.defaultServingID })
        #expect(serving.label == "1 shot")
        #expect(serving.grams == 60)

        let stored = try #require(try h.foods.food(barcodes: [Self.perServingCode]))
        #expect(stored.food.id == saved.food.id)
        #expect(!stored.food.perServingOnly)
        let updated = try found(h.model)
        #expect(!updated.needsServingWeight)
        #expect(updated.per100?.kcal == saved.food.kcal100)
        // One serving still gives the label's values.
        #expect(abs(Quantity.servings(count: 1, serving: serving.size).nutrients(per100: stored.food.per100).kcal - 12) < 1e-9)
    }

    @Test func `placeholder conversion keeps partial quality when macros are missing`() {
        var food = Food(name: "Bar", per100: Nutrients(kcal: 200, proteinG: 0, carbsG: 0, fatG: 0), dataQuality: .partialMacros)
        food.perServingOnly = true
        let serving = Serving(label: "1 bar", grams: 100)
        food.defaultServingID = serving.id
        let detail = FoodDetail(food: food, servings: [serving])
        let converted = ScanFlowModel.convertingPlaceholder(detail, servingWeight: 40, missing: [.protein])
        #expect(converted.food.dataQuality == .partialMacros)
        #expect(converted.food.kcal100 == 500)
        #expect(converted.servings.first?.grams == 40)
    }

    // MARK: Review follow-ups

    @Test func `complete nutrition waits for the serving weight on a placeholder`() async throws {
        let h = harness()
        await h.model.handle([Self.perServingEnergyOnlyCode])
        let product = try found(h.model)
        #expect(product.needsServingWeight)
        #expect(!product.needsCompletion) // serving weight first
        #expect(throws: (any Error).self) { try h.model.foodForCompletingNutrition() }

        let converted = try h.model.setServingWeight(50)
        #expect(!converted.food.perServingOnly)
        #expect(converted.food.dataQuality == .partialMacros) // macros still missing
        let afterWeight = try found(h.model)
        #expect(afterWeight.needsCompletion)
        #expect(afterWeight.missing == [.protein, .carbs, .fat])

        let request = try h.model.foodForCompletingNutrition()
        let editor = FoodEditorModel(energyUnit: .kcal, editing: request.detail, completing: request.missing)
        #expect(editor.energy == "300") // 150 kcal per 50 g
        editor.protein = "20"
        editor.carbs = "40"
        editor.fat = "16"
        let saved = try h.foods.save(#require(editor.makeDetail()))
        h.model.nutritionCompleted(saved)

        let stored = try #require(try h.foods.detail(id: saved.food.id))
        #expect(stored.food.dataQuality == .complete)
        #expect(!stored.food.perServingOnly)
        let serving = try #require(stored.servings.first { $0.id == stored.food.defaultServingID })
        #expect(serving.grams == 50)
        let oneServing = Quantity.servings(count: 1, serving: serving.size).nutrients(per100: stored.food.per100)
        #expect(abs(oneServing.kcal - 150) < 1e-9)
        #expect(try found(h.model).missing == [])
    }

    @Test func `re-scanned zero-macro placeholder doesn't guess missing values`() async throws {
        let h = harness()
        await h.model.handle([Self.perServingCode]) // protein and fat are a real 0 per serving
        _ = try h.model.foodForLogging()

        h.client.setFailure(.offline)
        let rescan = h.newSession()
        await rescan.handle([Self.perServingCode])
        let product = try found(rescan)
        #expect(product.isSaved)
        #expect(product.needsServingWeight)
        #expect(product.missing == nil)
        #expect(!product.isMissing(.protein))
        #expect(!product.needsCompletion)

        // Unknown missing values: converting keeps the data partial for the user to review.
        let converted = try rescan.setServingWeight(60)
        #expect(!converted.food.perServingOnly)
        #expect(converted.food.dataQuality == .partialMacros)
        #expect(try found(rescan).needsCompletion)
    }

    @Test func `a lookup answer that arrives after closing is discarded`() async {
        let h = harness()
        h.client.setDelay(.milliseconds(300))
        let lookup = Task { await h.model.handle([Self.nutella]) }
        #expect(await waitUntil { h.model.isResolving })
        h.model.resumeScanning() // "Scan another" / closed while the lookup runs
        await lookup.value
        #expect(h.model.phase == .scanning)
        #expect(h.client.requests == [Self.nutella])
    }

    @Test func `retry keeps the failure screen up while it runs`() async throws {
        let h = harness(failure: .offline)
        await h.model.handle([Self.nutella])
        h.client.setFailure(nil)
        h.client.setDelay(.milliseconds(200))
        let retry = Task { await h.model.retry() }
        #expect(await waitUntil { h.model.isRetrying })
        #expect(h.model.phase == .failed(.offline, candidates: [Self.nutella]))
        #expect(h.model.showsResult)
        await retry.value
        #expect(!h.model.isRetrying)
        #expect(try found(h.model).food.name == "Nutella")
    }

    @Test func `no database gives a failure instead of hanging`() async {
        let model = ScanFlowModel(lookup: nil, foods: nil, labelPhotos: .temporary())
        await model.handle([Self.nutella])
        guard case .failed(.other, _) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(model.showsResult)
    }

    @Test func `quantity sheet logs a placeholder by servings with the label's values`() async throws {
        let h = harness()
        await h.model.handle([Self.perServingCode])
        let detail = try h.model.foodForLogging()
        #expect(detail.isPerServingPlaceholder)
        #expect(!QuantitySheet.offersBaseUnit(detail))

        // Prefilled with 1 × the printed serving, never grams.
        let initial = QuantitySheet.initialLogQuantity(detail)
        guard case let .servings(count, size) = initial.quantity else {
            Issue.record("expected servings, got \(initial.quantity)")
            return
        }
        #expect(count == 1)
        #expect(size.label == "1 shot")
        let servingID = try #require(detail.food.defaultServingID)
        #expect(QuantitySheet.quantity(amountText: "100", unitChoice: "base", detail: detail) == nil)

        let quantity = try #require(QuantitySheet.quantity(amountText: "1", unitChoice: servingID, detail: detail))
        let entry = try #require(h.env.diary).log(
            food: detail.food, quantity: quantity, servingID: servingID, slotID: "breakfast", day: h.env.today,
        )
        #expect(abs(entry.kcal - 12) < 1e-9)
        #expect(abs(entry.carbsG - 2.7) < 1e-9)
    }

    @Test func `label photos are downsampled to 1600 px`() throws {
        func jpeg(width: CGFloat, height: CGFloat) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
                .jpegData(withCompressionQuality: 0.9) { context in
                    UIColor.systemOrange.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
        }
        func pixelSize(_ data: Data) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return (image.width, image.height)
        }

        let large = try #require(LabelPhotoStore.downsampledJPEG(jpeg(width: 3200, height: 400)))
        let (largeWidth, largeHeight) = try pixelSize(large)
        #expect(largeWidth == 1600)
        #expect(largeHeight == 200)

        let small = try #require(LabelPhotoStore.downsampledJPEG(jpeg(width: 120, height: 80)))
        let (smallWidth, smallHeight) = try pixelSize(small)
        #expect(smallWidth == 120)
        #expect(smallHeight == 80)

        #expect(LabelPhotoStore.downsampledJPEG(Data("not an image".utf8)) == nil)
    }
}
