import Core
import FoodLookup
import FoodSources
import Foundation
import Observation
import Persistence

/// State of the scan flow (backlog #20, FR-10–FR-14, SPEC §9): scan → resolve → product card → quantity → log, or
/// not found / offline → create food. The views only present this state; everything testable lives here.
@MainActor
@Observable
final class ScanFlowModel {
    enum Phase: Equatable {
        /// The camera is waiting for a code.
        case scanning
        /// Looking the code up (local database, cache, Open Food Facts).
        case resolving(candidates: [String])
        /// Show the product card.
        case found(ScannedProduct)
        /// Nobody knows the code: offer to create the food with the barcode prefilled.
        case notFound(barcode: String)
        /// The lookup failed (offline / OFF unavailable); retry or create the food by hand.
        case failed(Failure, candidates: [String])
    }

    enum Failure: Equatable {
        case offline
        case unavailable
        case other(String)

        var title: String {
            switch self {
            case .offline: "You're offline"
            case .unavailable: "Open Food Facts isn't answering"
            case .other: "Couldn't look up this barcode"
            }
        }

        var message: String {
            switch self {
            case .offline:
                "This product isn't saved on your phone yet, so it needs a connection. Try again when you're online, "
                    + "or create the food from its label now."
            case .unavailable:
                "Try again in a moment, or create the food from its label now."
            case let .other(detail):
                detail
            }
        }
    }

    /// One food logged during this scanner session (continuous mode).
    struct LoggedItem: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let foodID: String
    }

    /// What happens after a food is logged.
    enum LogOutcome: Equatable {
        /// Continuous mode: back to the camera.
        case keepScanning
        /// Close the scanner (and Add Food).
        case close
    }

    private(set) var phase: Phase = .scanning
    /// "Try again" is looking the failed code up again. The failure screen stays up meanwhile (closing and reopening
    /// the sheet could race with its dismissal and leave no sheet at all).
    private(set) var isRetrying = false
    /// Short message shown over the camera, e.g. for a code that isn't a product barcode.
    private(set) var notice: String?
    /// "Keep scanning": after logging, go back to the camera instead of closing (shopping-list style).
    var keepScanning = false
    /// Foods logged since the scanner opened.
    private(set) var sessionLog: [LoggedItem] = []

    /// A label photo taken on the not-found screen, saved with the food once it is created (FR-13).
    var pendingLabelPhoto: Data?
    /// Set when the label photo couldn't be stored.
    private(set) var labelPhotoError: String?

    private let lookup: BarcodeLookup?
    private let foods: FoodRepository?
    let labelPhotos: LabelPhotoStore
    /// Bumped whenever a lookup starts or is abandoned, so a late answer can't replace newer state.
    private var generation = 0

    init(lookup: BarcodeLookup?, foods: FoodRepository?, labelPhotos: LabelPhotoStore) {
        self.lookup = lookup
        self.foods = foods
        self.labelPhotos = labelPhotos
    }

    convenience init(environment: AppEnvironment) {
        self.init(lookup: environment.barcodeLookup, foods: environment.foods, labelPhotos: environment.labelPhotos)
    }

    var loggedCount: Int {
        sessionLog.count
    }

    /// True while something other than the camera should be shown (product card, not found, error).
    var showsResult: Bool {
        switch phase {
        case .scanning, .resolving: false
        case .found, .notFound, .failed: true
        }
    }

    var isResolving: Bool {
        if case .resolving = phase {
            return true
        }
        return false
    }

    var product: ScannedProduct? {
        if case let .found(product) = phase {
            return product
        }
        return nil
    }

    // MARK: Scanning

    /// A code from the camera or manual entry. Ignored unless the camera is waiting (a card is open, or a lookup runs).
    func handle(_ candidates: [String]) async {
        guard phase == .scanning else { return }
        notice = nil
        guard !candidates.isEmpty else {
            notice = "That code isn't a product barcode."
            return
        }
        await resolve(candidates)
    }

    /// Looks the last failed code up again, keeping the failure screen up (with progress) until the answer arrives.
    func retry() async {
        guard case let .failed(_, candidates) = phase, !isRetrying else { return }
        await resolve(candidates, retrying: true)
    }

    /// Back to the camera (card dismissed, "Scan another").
    func resumeScanning() {
        generation += 1
        isRetrying = false
        phase = .scanning
        pendingLabelPhoto = nil
        labelPhotoError = nil
    }

    private func resolve(_ candidates: [String], retrying: Bool = false) async {
        guard let lookup else {
            phase = .failed(.other("The food database couldn't be opened."), candidates: candidates)
            return
        }
        generation += 1
        let token = generation
        if retrying {
            isRetrying = true
        } else {
            phase = .resolving(candidates: candidates)
        }
        let next: Phase?
        do {
            next = try await Self.phase(for: lookup.resolve(candidates: candidates))
        } catch is CancellationError {
            if token == generation {
                isRetrying = false
                if !retrying {
                    phase = .scanning
                }
            }
            return
        } catch {
            next = Self.phase(for: error, candidates: candidates)
        }
        guard token == generation else { return } // closed or rescanned meanwhile
        isRetrying = false
        if let next {
            phase = next
        } else {
            phase = .scanning
            notice = "That code isn't a product barcode."
        }
    }

    private static func phase(for result: BarcodeLookupResult) -> Phase {
        switch result {
        case let .local(detail): .found(ScannedProduct(local: detail))
        case let .remote(remote): .found(ScannedProduct(remote: remote))
        case let .notFound(barcode): .notFound(barcode: barcode)
        }
    }

    /// The failure screen for a lookup error; nil for an invalid barcode (stay on the camera).
    private static func phase(for error: any Error, candidates: [String]) -> Phase? {
        switch error {
        case BarcodeLookupError.invalidBarcode: nil
        case BarcodeLookupError.offline: .failed(.offline, candidates: candidates)
        case BarcodeLookupError.unavailable: .failed(.unavailable, candidates: candidates)
        default: .failed(.other(error.localizedDescription), candidates: candidates)
        }
    }

    // MARK: Product card actions

    /// The food to hand to the quantity sheet. An Open Food Facts product is saved as a local food first
    /// (`saveRemoteCopy`, idempotent), so the entry links to it and the next scan works offline.
    func foodForLogging() throws -> FoodDetail {
        try ensureSaved().detail
    }

    /// The local food to open in the editor for "Complete nutrition", and which values the source is missing.
    ///
    /// Not for a per-serving placeholder: its values are per serving, which the editor would show as per 100 (and
    /// editing the stand-in serving would break "1 serving"). Set the serving weight first (``setServingWeight(_:)``).
    func foodForCompletingNutrition() throws -> (detail: FoodDetail, missing: Set<FoodEditorModel.RequiredNutrient>) {
        guard product?.needsServingWeight != true else {
            throw PersistenceError.validation("enter the serving weight first")
        }
        let product = try ensureSaved()
        return (product.detail, product.missing ?? [])
    }

    /// The editor saved the completed food: show it (the local copy now holds the user's values, and the editor
    /// validated all four required ones).
    func nutritionCompleted(_ saved: FoodDetail) {
        guard var product else { return }
        product.detail = saved
        product.isSaved = true
        product.missing = []
        phase = .found(product)
    }

    /// Sets the real serving weight of a per-serving placeholder (values were per serving, stored as per 100 with a
    /// 100 g/ml stand-in serving): converts the values to per 100, gives the serving its weight and clears
    /// `perServingOnly`. Saves the local copy first when needed.
    @discardableResult
    func setServingWeight(_ amount: Double) throws -> FoodDetail {
        guard let foods else { throw PersistenceError.validation("database unavailable") }
        guard amount > 0, amount.isFinite else { throw PersistenceError.validation("serving weight must be greater than zero") }
        var product = try ensureSaved()
        guard product.detail.isPerServingPlaceholder else { return product.detail }
        let converted = Self.convertingPlaceholder(product.detail, servingWeight: amount, missing: product.missing)
        let saved = try foods.save(converted)
        product.detail = saved
        product.isSaved = true
        // No longer a placeholder: an unknown missing set now follows the normal rule for partial foods.
        product.missing = saved.food.dataQuality == .complete ? [] : product.missing ?? ScannedProduct.inferredMissing(saved.food)
        phase = .found(product)
        return saved
    }

    /// `detail` (a per-serving placeholder) with values per 100 for a serving of `servingWeight` g/ml. `missing` nil
    /// means unknown (a placeholder found locally): the quality then stays partial.
    nonisolated static func convertingPlaceholder(
        _ detail: FoodDetail,
        servingWeight: Double,
        missing: Set<FoodEditorModel.RequiredNutrient>?,
    ) -> FoodDetail {
        var result = detail
        var food = detail.food
        food.per100 = Nutrients.per100(fromServing: food.per100, servingGrams: servingWeight)
        food.perServingOnly = false
        // Per-serving values were partial only because the weight was unknown; missing macros keep them partial.
        if missing?.isEmpty == true, food.dataQuality == .partialMacros {
            food.dataQuality = .complete
        }
        if food.notes?.hasPrefix("Nutrition per serving;") == true {
            food.notes = nil
        }
        result.servings = detail.servings.map { serving in
            guard serving.id == food.defaultServingID else { return serving }
            var updated = serving
            updated.grams = servingWeight
            return updated
        }
        result.food = food
        return result
    }

    /// Call after the quantity sheet logged the food. Returns whether to keep scanning or close the scanner.
    func didLog(_ detail: FoodDetail) -> LogOutcome {
        sessionLog.append(LoggedItem(name: detail.food.displayName, foodID: detail.food.id))
        guard keepScanning else { return .close }
        resumeScanning()
        return .keepScanning
    }

    // MARK: Not found

    /// The user created the food for a code nobody knew: show its card so it can be logged right away.
    /// Stores a pending label photo under the new food's ID (app container only, never the database).
    func foodCreated(_ saved: FoodDetail) {
        if let photo = pendingLabelPhoto {
            do {
                try labelPhotos.save(photo, foodID: saved.food.id)
                pendingLabelPhoto = nil
            } catch {
                labelPhotoError = "The label photo couldn't be saved: \(error.localizedDescription)"
            }
        }
        phase = .found(ScannedProduct(local: saved))
    }

    /// The code to prefill when creating the food by hand (not found, or offline).
    var barcodeForNewFood: String? {
        switch phase {
        case let .notFound(barcode): barcode
        case let .failed(_, candidates): candidates.first
        default: nil
        }
    }

    // MARK: Helpers

    /// The current product, saved as a local food (a no-op for local ones).
    private func ensureSaved() throws -> ScannedProduct {
        guard var product else { throw PersistenceError.validation("no product") }
        guard !product.isSaved, let remote = product.remote else { return product }
        guard let foods else { throw PersistenceError.validation("database unavailable") }
        product.detail = try foods.saveRemoteCopy(remote.draft)
        product.isSaved = true
        // `saveRemoteCopy` may return a food the user already completed.
        if product.detail.food.dataQuality == .complete {
            product.missing = []
        }
        phase = .found(product)
        return product
    }
}

/// A scanned product as shown on the card: either a local food or an Open Food Facts product (unsaved until it is
/// logged, completed or given a serving weight).
struct ScannedProduct: Equatable {
    /// The food, or for an unsaved OFF product what `saveRemoteCopy` will store (same values, same placeholder rule).
    var detail: FoodDetail
    /// True once `detail` is in the database.
    var isSaved: Bool
    /// The OFF answer, when the product came from Open Food Facts in this scan.
    var remote: RemoteProduct?
    /// Required nutrients the source doesn't have (shown empty by "Complete nutrition"); nil when unknown (a
    /// per-serving placeholder found locally, whose zeros may be real).
    var missing: Set<FoodEditorModel.RequiredNutrient>?

    init(local detail: FoodDetail) {
        self.detail = detail
        isSaved = true
        remote = nil
        // A placeholder's values are per serving, so its zeros say nothing about what the source lacked.
        missing = detail.food.perServingOnly ? nil : Self.inferredMissing(detail.food)
    }

    init(remote: RemoteProduct) {
        detail = FoodDetail(draft: remote.draft)
        isSaved = false
        self.remote = remote
        missing = Set(remote.draft.missingNutrients.compactMap { FoodEditorModel.RequiredNutrient(rawValue: $0.rawValue) })
    }

    var food: Food {
        detail.food
    }

    var barcode: String? {
        remote?.barcode ?? detail.barcodes.first
    }

    var imageURL: URL? {
        food.imageURL.flatMap(URL.init(string:))
    }

    /// Nutri-Score grade "A"…"E" when known.
    var nutriscore: String? {
        guard let grade = food.nutriscore?.uppercased(), ["A", "B", "C", "D", "E"].contains(grade) else { return nil }
        return grade
    }

    /// Served from an expired cache entry because Open Food Facts couldn't be reached.
    var isStale: Bool {
        remote?.isStale ?? false
    }

    /// Show the "Complete nutrition" CTA: the data is partial. Not for a per-serving placeholder: it gets the
    /// serving-weight prompt first (see ``ScanFlowModel/foodForCompletingNutrition()``).
    var needsCompletion: Bool {
        food.dataQuality != .complete && !needsServingWeight
    }

    /// Whether a required value is known to be missing (shown as "—").
    func isMissing(_ nutrient: FoodEditorModel.RequiredNutrient) -> Bool {
        food.dataQuality != .complete && missing?.contains(nutrient) == true
    }

    /// The real serving weight is unknown: ask for it, hide gram entry.
    var needsServingWeight: Bool {
        detail.isPerServingPlaceholder
    }

    /// Per-100 values; nil for a per-serving placeholder, whose stored values are really per serving.
    var per100: Nutrients? {
        needsServingWeight ? nil : food.per100
    }

    /// The default (else first) serving with its nutrients. For a placeholder, the printed serving with its values
    /// and no weight.
    var serving: (label: String, amount: Double?, nutrients: Nutrients)? {
        let chosen = detail.servings.first { $0.id == food.defaultServingID } ?? detail.servings.first
        guard let chosen else { return nil }
        if needsServingWeight {
            return (chosen.label, nil, food.per100)
        }
        return (chosen.label, chosen.grams, food.per100.scaled(toGrams: chosen.grams))
    }

    /// Mandatory values that are 0 on a partial local food: the source didn't have them (an energy-only food is
    /// missing all three macros). A real 0 must then be typed in again, which is cheap.
    static func inferredMissing(_ food: Food) -> Set<FoodEditorModel.RequiredNutrient> {
        switch food.dataQuality {
        case .complete:
            return []
        case .energyOnly:
            return [.protein, .carbs, .fat]
        case .partialMacros:
            var missing: Set<FoodEditorModel.RequiredNutrient> = []
            if food.kcal100 == 0 {
                missing.insert(.energy)
            }
            if food.proteinG100 == 0 {
                missing.insert(.protein)
            }
            if food.carbsG100 == 0 {
                missing.insert(.carbs)
            }
            if food.fatG100 == 0 {
                missing.insert(.fat)
            }
            return missing
        }
    }
}
