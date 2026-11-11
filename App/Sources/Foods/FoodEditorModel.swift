import Core
import FoodLookup
import FoodSources
import Foundation
import Observation
import Persistence

/// Form state for creating / editing a custom food (backlog #9, FR-23).
@MainActor
@Observable
final class FoodEditorModel {
    enum InputBasis: String, CaseIterable, Identifiable {
        case per100 = "Per 100 g/ml"
        case perServing = "Per serving"
        var id: String {
            rawValue
        }
    }

    /// The nutrients every food must have; listed when completing a partial food (SPEC §9 "Complete nutrition").
    enum RequiredNutrient: String, CaseIterable, Hashable, Sendable {
        case energy, protein, carbs, fat
    }

    struct ServingDraft: Identifiable, Equatable {
        var id: String = newID()
        var label: String = ""
        var amount: String = ""
    }

    /// One barcode row. A stable id keeps the text field, swipe-to-delete and the remove button on the right row
    /// while rows are added and removed.
    struct BarcodeDraft: Identifiable, Equatable {
        var id: String = newID()
        var code: String = ""
    }

    /// What a scan did to the barcode list.
    enum ScanResult: Equatable {
        /// The normalized code was added.
        case added(String)
        /// The code (in any of its readings) is already in the list.
        case duplicate(String)
        /// Not a retail product code (e.g. a Code-128 lot number).
        case invalid
    }

    /// A barcode in the form that another active food carries (in any reading of its digits). Saving moves it here
    /// only after the user agrees (`FoodRepository.save(_:movingBarcodes:)`), never silently.
    struct BarcodeConflict: Equatable, Identifiable {
        /// The code as listed in the editor.
        var barcode: String
        /// The key the other food stores it under (another reading for some 8-digit codes).
        var storedBarcode: String
        var foodID: String
        var foodName: String

        init(barcode: String, storedBarcode: String? = nil, foodID: String, foodName: String) {
            self.barcode = barcode
            self.storedBarcode = storedBarcode ?? barcode
            self.foodID = foodID
            self.foodName = foodName
        }

        var id: String {
            storedBarcode
        }
    }

    // Identity
    var name = ""
    var nameLocal = ""
    var brand = ""
    var notes = ""
    var isLiquid = false

    // Nutrition input
    var basis: InputBasis = .per100
    var basisServingAmount = "" // g/ml of one serving when basis == .perServing
    var energy = "" // in the display energy unit
    var protein = ""
    var carbs = ""
    var fat = ""
    var fiber = ""
    var sugar = ""
    var satFat = ""
    var sodiumOrSalt = ""
    var entersSalt = true // EU labels show salt; US labels sodium
    var caffeine = "" // mg

    var servings: [ServingDraft] = []
    var defaultServingID: String?
    var barcodeRows: [BarcodeDraft] = []
    /// Normalized code → name of the other active food carrying it (`refreshBarcodeOwners(in:)`), for the row hint.
    private(set) var barcodeOwners: [String: String] = [:]

    /// The barcode texts in row order (empty rows included).
    var barcodes: [String] {
        get { barcodeRows.map(\.code) }
        set { barcodeRows = newValue.map { BarcodeDraft(code: $0) } }
    }

    let energyUnit: EnergyUnit
    private(set) var original: FoodDetail?
    /// Set when completing the nutrition of a partial food: these fields start empty so they must be typed in,
    /// and saving marks the food's data complete.
    private(set) var completing: Set<RequiredNutrient>?

    /// Nutrition fields as loaded from `original`. Fields still showing this text keep the stored value on
    /// save: the fields round to 2 decimals, and USDA / Open Food Facts values often have more.
    private struct LoadedFields {
        var energy, protein, carbs, fat, fiber, sugar, satFat, sodiumOrSalt, caffeine: String
        var entersSalt: Bool
    }

    private var loaded: LoadedFields?

    /// - Parameter completing: Complete-nutrition mode for a partial food (`detail` required): the given
    ///   nutrients are missing in the source, so their fields start empty; saving marks the data complete.
    init(
        energyUnit: EnergyUnit,
        editing detail: FoodDetail? = nil,
        initialName: String = "",
        barcode: String? = nil,
        completing: Set<RequiredNutrient>? = nil,
    ) {
        self.energyUnit = energyUnit
        original = detail
        name = initialName
        if let barcode {
            barcodes = [barcode]
        }
        if let detail {
            load(detail)
            if let completing {
                self.completing = completing
                for field in completing {
                    switch field {
                    case .energy: energy = ""
                    case .protein: protein = ""
                    case .carbs: carbs = ""
                    case .fat: fat = ""
                    }
                }
            }
        }
    }

    var isEditing: Bool {
        original != nil
    }

    var unitSymbol: String {
        isLiquid ? "ml" : "g"
    }

    // MARK: Derived values

    /// Per-100 nutrients from the inputs, or nil when a required value is missing/invalid.
    var per100: Nutrients? {
        guard let kcalInput = Self.value(energy), let p = Self.value(protein), let c = Self.value(carbs), let f = Self.value(fat)
        else { return nil }
        let optionals = [fiber, sugar, satFat, sodiumOrSalt, caffeine]
        guard optionals.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || Self.value($0) != nil }) else { return nil }
        let sodiumInput = Self.value(sodiumOrSalt)
        let entered = Nutrients(
            kcal: energyUnit.fromDisplay(kcalInput), proteinG: p, carbsG: c, fatG: f,
            fiberG: Self.value(fiber), sugarG: Self.value(sugar), satFatG: Self.value(satFat),
            sodiumMg: sodiumInput.map { entersSalt ? Salt.sodiumMg(fromSaltG: $0) : $0 },
            caffeineMg: Self.value(caffeine),
        )
        switch basis {
        case .per100:
            return entered
        case .perServing:
            guard let grams = Self.value(basisServingAmount), grams > 0 else { return nil }
            return Nutrients.per100(fromServing: entered, servingGrams: grams)
        }
    }

    /// Problems that block saving.
    var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Enter a name.")
        }
        if basis == .perServing, (Self.value(basisServingAmount) ?? 0) <= 0 {
            errors.append("Enter the serving size.")
        }
        if per100 == nil {
            errors.append("Enter energy, protein, carbs and fat (numbers ≥ 0).")
        }
        for serving in servings where !serving.label.isEmpty || !serving.amount.isEmpty {
            if serving.label.trimmingCharacters(in: .whitespaces).isEmpty || (Self.value(serving.amount) ?? 0) <= 0 {
                errors.append("Each serving needs a name and an amount.")
                break
            }
        }
        for code in barcodes where !code.trimmingCharacters(in: .whitespaces).isEmpty && Barcode.normalize(code) == nil {
            errors.append("Barcode \(code) is not valid.")
        }
        return errors
    }

    /// Non-blocking warnings (backlog #9: plausibility check, don't block).
    var warnings: [String] {
        guard let n = per100 else { return [] }
        var result: [String] = []
        if n.hasImplausibleEnergy() {
            let estimate = Int(n.kcalFromMacros.rounded())
            result.append("Energy differs from protein/carbs/fat (≈ \(estimate) kcal per 100). Double-check the label.")
        }
        if n.proteinG + n.carbsG + n.fatG > 100.5 {
            result.append("Protein + carbs + fat exceed 100 g per 100 g.")
        }
        if let sugar = n.sugarG, sugar > n.carbsG + 0.05 {
            result.append("Sugars are higher than carbohydrates.")
        }
        if let sat = n.satFatG, sat > n.fatG + 0.05 {
            result.append("Saturated fat is higher than total fat.")
        }
        return result
    }

    var canSave: Bool {
        validationErrors.isEmpty
    }

    // MARK: Building the record

    func makeDetail() -> FoodDetail? {
        guard canSave, let per100 else { return nil }
        var food = original?.food ?? Food(name: "", per100: per100)
        food.name = name.trimmingCharacters(in: .whitespaces)
        food.nameLocal = Self.optional(nameLocal)
        food.brand = Self.optional(brand)
        food.notes = Self.optional(notes)
        food.isLiquid = isLiquid
        food.per100 = keepingUneditedValues(per100)
        // Editing a bundled / USDA / Open Food Facts food keeps its data-quality flag, unless the user just completed
        // its nutrition (all four required values are validated numbers). Per-serving placeholders stay partial
        // until their serving weight is known.
        if completing != nil, !food.perServingOnly {
            food.dataQuality = .complete
        } else {
            food.dataQuality = original?.food.dataQuality ?? .complete
        }
        let drafts = servings.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        let savedServings = drafts.map { draft in
            let old = original?.servings.first { $0.id == draft.id }
            var serving = old ?? Serving(id: draft.id, label: "", grams: 1)
            serving.label = draft.label.trimmingCharacters(in: .whitespaces)
            if let old, draft.amount == Format.field(old.grams) {
                serving.grams = old.grams // amount not edited: keep the unrounded value
            } else {
                serving.grams = Self.value(draft.amount) ?? 1
            }
            return serving
        }
        food.defaultServingID = savedServings.contains { $0.id == defaultServingID } ? defaultServingID : nil
        return FoodDetail(
            food: food, servings: savedServings,
            barcodes: barcodes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
        )
    }

    func addServing() {
        servings.append(ServingDraft())
    }

    // MARK: Barcodes

    /// Adds an empty row to type a code into.
    func addBarcodeRow() {
        barcodeRows.append(BarcodeDraft())
    }

    func removeBarcode(id: BarcodeDraft.ID) {
        barcodeRows.removeAll { $0.id == id }
    }

    func removeBarcodes(atOffsets offsets: IndexSet) {
        barcodeRows.remove(atOffsets: offsets)
    }

    /// Adds a scanned (or typed-in-the-scanner) code: its normalized form (`ScannedBarcode.candidates`, most likely
    /// first) goes into the first empty row or a new one. A code already listed in any of its readings — an
    /// 8-digit code can be EAN-8 or UPC-E — isn't added twice.
    @discardableResult
    func insertScanned(candidates: [String]) -> ScanResult {
        guard let code = candidates.first else { return .invalid }
        let scanned = Set(candidates)
        if let row = barcodeRows.first(where: { !scanned.isDisjoint(with: Barcode.candidates($0.code)) }) {
            return .duplicate(Barcode.normalize(row.code) ?? row.code) // as the list shows it
        }
        if let empty = barcodeRows.firstIndex(where: { $0.code.trimmingCharacters(in: .whitespaces).isEmpty }) {
            barcodeRows[empty].code = code
        } else {
            barcodeRows.append(BarcodeDraft(code: code))
        }
        return .added(code)
    }

    // MARK: Product lookup (#69)

    /// What looking a scanned code up did to the form.
    enum ScanLookup: Equatable {
        /// Open Food Facts knows the product (`name`): its values were filled in.
        case filled(name: String)
        /// One of the user's foods already carries the code; nothing was filled in.
        case existing(name: String)
        /// Nobody knows the code: the values have to be typed from the label.
        case notFound
        /// The lookup failed (offline, Open Food Facts not answering).
        case failed
        /// Not looked up: an existing food is being edited, or nutrition values were typed already.
        case skipped
    }

    /// A lookup may fill the form of a new food while none of the required nutrition values is typed in — it never
    /// overwrites what the user entered and never changes an existing food.
    var canFillFromLookup: Bool {
        original == nil && [energy, protein, carbs, fat].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Looks a scanned code up — your foods, then Open Food Facts, like the scanner of Add Food — and fills the form
    /// of a new food with the product found.
    func lookUpScanned(candidates: [String], using lookup: BarcodeLookup?) async -> ScanLookup {
        guard canFillFromLookup, let lookup, !candidates.isEmpty else { return .skipped }
        let result: BarcodeLookupResult
        do {
            result = try await lookup.resolve(candidates: candidates)
        } catch {
            return .failed
        }
        switch result {
        case let .local(detail):
            return .existing(name: detail.food.displayName)
        case .notFound:
            return .notFound
        case let .remote(remote):
            guard canFillFromLookup else { return .skipped } // values were typed while the lookup ran
            let missing = Set(remote.draft.missingNutrients.compactMap { RequiredNutrient(rawValue: $0.rawValue) })
            let product = FoodDetail(draft: remote.draft)
            fill(from: product, missing: missing)
            return .filled(name: product.food.name)
        }
    }

    /// Fills a new food's form with a product's values; a name or brand already typed is kept. The food stays a new
    /// custom food. Values the source doesn't have stay empty, and a product known only per serving switches the
    /// form to "Per serving" so the serving size is asked for.
    func fill(from product: FoodDetail, missing: Set<RequiredNutrient> = []) {
        let food = product.food
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = food.name
        }
        if nameLocal.isEmpty {
            nameLocal = food.nameLocal ?? ""
        }
        if brand.isEmpty {
            brand = food.brand ?? ""
        }
        isLiquid = food.isLiquid
        energy = missing.contains(.energy) ? "" : Format.field(energyUnit.display(food.kcal100))
        protein = missing.contains(.protein) ? "" : Format.field(food.proteinG100)
        carbs = missing.contains(.carbs) ? "" : Format.field(food.carbsG100)
        fat = missing.contains(.fat) ? "" : Format.field(food.fatG100)
        fiber = Format.field(food.fiberG100)
        sugar = Format.field(food.sugarG100)
        satFat = Format.field(food.satFatG100)
        entersSalt = false
        sodiumOrSalt = Format.field(food.sodiumMg100)
        caffeine = Format.field(food.caffeineMg100)
        if product.isPerServingPlaceholder {
            // The stored values are per serving of unknown weight.
            basis = .perServing
            basisServingAmount = ""
        } else {
            basis = .per100
            if servings.allSatisfy({ $0.label.isEmpty && $0.amount.isEmpty }) {
                servings = product.servings.map { ServingDraft(id: $0.id, label: $0.label, amount: Format.field($0.grams)) }
                defaultServingID = servings.contains { $0.id == food.defaultServingID } ? food.defaultServingID : nil
            }
        }
    }

    /// The normalized, valid, de-duplicated codes the food will be saved with.
    var normalizedBarcodes: [String] {
        barcodeRows.compactMap { Barcode.normalize($0.code) }.reduce(into: []) { result, code in
            if !result.contains(code) {
                result.append(code)
            }
        }
    }

    /// Codes in the list that another active food carries, also under another reading of the same digits.
    func barcodeConflicts(in foods: FoodRepository) throws -> [BarcodeConflict] {
        try foods.activeOwners(of: normalizedBarcodes, excluding: original?.food.id).map {
            BarcodeConflict(barcode: $0.barcode, storedBarcode: $0.storedBarcode, foodID: $0.food.id, foodName: $0.food.name)
        }
    }

    /// Re-reads which listed codes are on another food, for the row hint.
    func refreshBarcodeOwners(in foods: FoodRepository) {
        let conflicts = (try? barcodeConflicts(in: foods)) ?? []
        barcodeOwners = Dictionary(conflicts.map { ($0.barcode, $0.foodName) }) { first, _ in first }
    }

    /// The other food carrying the code typed in a row, if any.
    func owner(of code: String) -> String? {
        Barcode.normalize(code).flatMap { barcodeOwners[$0] }
    }

    /// "This barcode is on 'Nutella' — move it here?"; one line per food when there are several.
    static func conflictMessage(_ conflicts: [BarcodeConflict]) -> String {
        if conflicts.count == 1, let conflict = conflicts.first {
            return "This barcode is on '\(conflict.foodName)' — move it here?"
        }
        let lines = conflicts.map { "\($0.barcode) is on '\($0.foodName)'" }
        return "These barcodes are on other foods — move them here?\n" + lines.joined(separator: "\n")
    }

    /// What "Move here" passes to `save(to:movingBarcodes:)`: each stored code with the food the user agreed to take
    /// it from, so a code that changed owner meanwhile fails instead of being taken.
    static func moving(_ conflicts: [BarcodeConflict]) -> [String: String] {
        Dictionary(conflicts.map { ($0.storedBarcode, $0.foodID) }) { first, _ in first }
    }

    /// Saves the food. `movingBarcodes` are codes the user agreed to take from other foods (code → that food's id,
    /// see `barcodeConflicts(in:)`); any other conflict, or a code that changed owner meanwhile, fails with
    /// `PersistenceError.barcodeInUse`.
    @discardableResult
    func save(to foods: FoodRepository, movingBarcodes: [String: String] = [:]) throws -> FoodDetail? {
        guard let detail = makeDetail() else { return nil }
        return try foods.save(detail, movingBarcodes: movingBarcodes)
    }

    // MARK: Helpers

    /// `entered` with every nutrient whose field the user left as loaded replaced by the stored value.
    private func keepingUneditedValues(_ entered: Nutrients) -> Nutrients {
        // Per-serving input reinterprets every field, so then all values are new.
        guard let stored = original?.food.per100, let loaded, basis == .per100 else { return entered }
        var result = entered
        if energy == loaded.energy {
            result.kcal = stored.kcal
        }
        if protein == loaded.protein {
            result.proteinG = stored.proteinG
        }
        if carbs == loaded.carbs {
            result.carbsG = stored.carbsG
        }
        if fat == loaded.fat {
            result.fatG = stored.fatG
        }
        if fiber == loaded.fiber {
            result.fiberG = stored.fiberG
        }
        if sugar == loaded.sugar {
            result.sugarG = stored.sugarG
        }
        if satFat == loaded.satFat {
            result.satFatG = stored.satFatG
        }
        if sodiumOrSalt == loaded.sodiumOrSalt, entersSalt == loaded.entersSalt {
            result.sodiumMg = stored.sodiumMg
        }
        if caffeine == loaded.caffeine {
            result.caffeineMg = stored.caffeineMg
        }
        return result
    }

    private func load(_ detail: FoodDetail) {
        let food = detail.food
        name = food.name
        nameLocal = food.nameLocal ?? ""
        brand = food.brand ?? ""
        notes = food.notes ?? ""
        isLiquid = food.isLiquid
        energy = Format.field(energyUnit.display(food.kcal100))
        protein = Format.field(food.proteinG100)
        carbs = Format.field(food.carbsG100)
        fat = Format.field(food.fatG100)
        fiber = Format.field(food.fiberG100)
        sugar = Format.field(food.sugarG100)
        satFat = Format.field(food.satFatG100)
        entersSalt = false
        sodiumOrSalt = Format.field(food.sodiumMg100)
        caffeine = Format.field(food.caffeineMg100)
        loaded = LoadedFields(
            energy: energy, protein: protein, carbs: carbs, fat: fat, fiber: fiber, sugar: sugar, satFat: satFat,
            sodiumOrSalt: sodiumOrSalt, caffeine: caffeine, entersSalt: entersSalt,
        )
        servings = detail.servings.map { ServingDraft(id: $0.id, label: $0.label, amount: Format.field($0.grams)) }
        defaultServingID = food.defaultServingID
        barcodes = detail.barcodes
    }

    static func value(_ text: String) -> Double? {
        guard let number = Format.number(text), number >= 0, number.isFinite else { return nil }
        return number
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
