import Core
import FoodSources
import Foundation
import Persistence

public extension DataQuality {
    /// The persisted quality for a source's quality (same raw values).
    init(_ quality: FoodDataQuality) {
        switch quality {
        case .complete: self = .complete
        case .partialMacros: self = .partialMacros
        case .energyOnly: self = .energyOnly
        }
    }
}

public extension FoodSource {
    /// The persisted source for a draft's origin (same raw values).
    init(_ origin: FoodDraft.Origin) {
        switch origin {
        case .off: self = .off
        case .usda: self = .usda
        }
    }
}

public extension FoodDetail {
    /// Label of the stand-in serving used when a draft only has per-serving values and no usable serving weight.
    /// Stored with the food in the app's language at copy time.
    static var perServingFallbackLabel: String {
        String(localized: "1 serving", bundle: .module, comment: "Name of a stand-in serving")
    }

    /// Note stored on a copy whose values are per serving and whose source gives no serving weight. Stored in the
    /// app's language at copy time; ``isPerServingPlaceholderNote(_:)`` recognizes it in English too.
    static var perServingUnknownWeightNote: String {
        String(
            localized: "Nutrition per serving; the serving weight is unknown, so 1 serving is counted as 100 g/ml.",
            bundle: .module,
        )
    }

    /// The English ``perServingUnknownWeightNote``, as stored before notes were localized.
    private static let englishPerServingUnknownWeightNote =
        "Nutrition per serving; the serving weight is unknown, so 1 serving is counted as 100 g/ml."

    /// Note stored on a copy whose values are per serving and whose serving weight (e.g. "0.5 g") is too small, or
    /// gives implausible per-100 values, to convert with. The weight is written in the user's locale ("0,5 g").
    static func perServingUnusableWeightNote(_ size: ServingSize, isLiquid: Bool, locale: Locale = .current) -> String {
        let weight = "\(NumberFormatting.compact(size.amount, locale: locale)) \(BaseUnit(isLiquid: isLiquid).symbol)"
        return unusableWeightNote(weight: weight)
    }

    /// The unusable-weight note around an already formatted `weight`.
    private static func unusableWeightNote(weight: String) -> String {
        String(
            localized: """
            Nutrition per serving; the serving weight given (\(weight)) can't be used to work out values per 100, \
            so 1 serving is counted as 100 g/ml.
            """,
            bundle: .module,
        )
    }

    /// A new, unsaved local food copied from an online `draft`, for ``FoodRepository/saveRemoteCopy(_:)`` (or
    /// `FoodRepository.saveCopy(_:)` after the caller edits it).
    ///
    /// - The name falls back to the brand, then the source ID, when the source has none.
    /// - Per-100 values are stored as is, with the draft's serving (when its weight is known) as the default serving.
    /// - Per-serving values (``FoodDraft/NutrientBasis/perServing``: no usable serving weight) are stored as if one
    ///   serving weighed 100 g/ml, with a stand-in default serving of 100 g/ml named after the printed serving, so
    ///   logging "1 serving" gives the right nutrients. `Food.perServingOnly` marks it
    ///   (``FoodDetail/isPerServingPlaceholder``), data quality stays partial, and a note says why.
    init(draft: FoodDraft) {
        let name = [draft.name, draft.brand, draft.sourceID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? draft.sourceID
        var food = Food(
            name: name,
            nameLocal: draft.nameLocal,
            brand: draft.brand,
            source: FoodSource(draft.origin),
            sourceID: draft.sourceID,
            per100: draft.nutrients,
            isLiquid: draft.isLiquid,
            dataQuality: DataQuality(draft.dataQuality),
        )
        food.imageURL = draft.imageURL?.absoluteString
        food.nutriscore = draft.nutriscore

        var serving: Serving?
        switch draft.basis {
        case .per100:
            if let size = draft.serving, size.amount > 0, size.amount <= Self.servingWeightRange.upperBound {
                serving = Serving(label: size.label, grams: size.amount)
            }
        case .perServing:
            let label = draft.servingDescription ?? draft.serving?.label ?? Self.perServingFallbackLabel
            serving = Serving(label: label, grams: 100)
            food.perServingOnly = true
            if let size = draft.serving, size.amount > 0, size.amount <= Self.servingWeightRange.upperBound {
                food.notes = Self.perServingUnusableWeightNote(size, isLiquid: draft.isLiquid)
            } else {
                food.notes = Self.perServingUnknownWeightNote
            }
        }
        if let serving {
            food.defaultServingID = serving.id
        }
        self.init(food: food, servings: serving.map { [$0] } ?? [], barcodes: draft.barcode.map { [$0] } ?? [])
    }
}

public extension FoodRepository {
    /// Stores a local copy of an online food (from a barcode scan or an online search) so it can be logged, and
    /// returns the stored food. Idempotent: returns the food already carrying the draft's barcode, else the copy
    /// with the same source + source ID (reviving it when deleted), else inserts a new one. See `saveCopy(_:)`.
    @discardableResult
    func saveRemoteCopy(_ draft: FoodDraft) throws -> FoodDetail {
        try saveCopy(FoodDetail(draft: draft))
    }
}

// MARK: - Serving weight for a per-serving placeholder

/// Why a serving weight can't be used to convert a per-serving placeholder.
public enum ServingWeightError: LocalizedError, Hashable, Sendable {
    /// Not a positive, finite amount.
    case notPositive
    /// Positive but outside ``FoodDetail/servingWeightRange`` (e.g. 0.00001 g or 1 000 000 g).
    case outOfRange
    /// The weight would give more energy per 100 than pure fat.
    case implausibleEnergy(kcalPer100: Double)
    /// The weight would give more than ~100 g of protein + carbs + fat per 100 g.
    case implausibleMacros(gramsPer100: Double)

    public var errorDescription: String? {
        switch self {
        case .notPositive:
            return String(localized: "Enter a weight above 0.", bundle: .module)
        case .outOfRange:
            let lower = Self.number(FoodDetail.servingWeightRange.lowerBound, fractionDigits: 1)
            let upper = Self.number(FoodDetail.servingWeightRange.upperBound)
            return String(localized: "Enter a weight between \(lower) and \(upper).", bundle: .module)
        case let .implausibleEnergy(kcal):
            let kcalText = Self.number(kcal)
            return String(
                localized: "That weight would mean \(kcalText) kcal per 100 — more than pure fat. Check the weight.",
                bundle: .module,
            )
        case let .implausibleMacros(grams):
            let gramsText = Self.number(grams)
            return String(
                localized: "That weight would mean \(gramsText) g of protein, carbs and fat per 100. Check the weight.",
                bundle: .module,
            )
        }
    }

    /// `value` for display without an `Int` conversion, so huge or non-finite values (a weight of 1e-17 g gives
    /// ~1e19 kcal per 100) can't trap. Follows `locale` ("0,1" in Croatian).
    static func number(_ value: Double, fractionDigits: Int = 0, locale: Locale = .current) -> String {
        guard value.isFinite else { return value.isNaN ? "?" : (value < 0 ? "-∞" : "∞") }
        return value.formatted(.number.precision(.fractionLength(0 ... fractionDigits)).locale(locale))
    }
}

public extension FoodDetail {
    /// Serving weights (g/ml) accepted by ``convertingPerServingPlaceholder(servingWeight:missing:)``.
    static let servingWeightRange = 0.1 ... 100_000.0

    /// Whether `note` is one of the notes ``init(draft:)`` stores on a per-serving placeholder (and nothing the user
    /// wrote).
    static func isPerServingPlaceholderNote(_ note: String?) -> Bool {
        guard let note else { return false }
        if note == perServingUnknownWeightNote || note == englishPerServingUnknownWeightNote {
            return true
        }
        if note.hasPrefix("Nutrition per serving; the serving weight given ("),
           note.hasSuffix("so 1 serving is counted as 100 g/ml.")
        {
            return true
        }
        // The note in the current language: the text around the weight, split at a marker standing in for it.
        let marker = "\u{1}"
        let parts = unusableWeightNote(weight: marker).components(separatedBy: marker)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return note.hasPrefix(parts[0]) && note.hasSuffix(parts[1]) && note.count > parts[0].count + parts[1].count
    }

    /// This per-serving placeholder (``isPerServingPlaceholder``: values per serving, stored as per 100 with a
    /// 100 g/ml stand-in serving) converted once the real serving weight is known — used by the scan flow and
    /// online search alike.
    ///
    /// - Values are scaled to per 100 for a serving of `servingWeight` g/ml; the default serving gets that weight
    ///   and `perServingOnly` is cleared.
    /// - Only the automatic per-serving note is removed; a note the user wrote stays.
    /// - Quality comes from the stored food: complete when no mandatory value is missing, otherwise the stored
    ///   quality is kept. `missing` is what the source lacks when known; `nil` infers it from the stored food
    ///   (a mandatory value of 0 counts as missing — a real 0 just keeps the food partial).
    /// - Throws ``ServingWeightError`` for a non-positive weight, one outside ``servingWeightRange``, or one that gives
    ///   implausible values per 100 (energy above `NutrientLimits.maxKcalPer100`, protein + carbs + fat above
    ///   `NutrientLimits.maxMacroSumPer100`).
    func convertingPerServingPlaceholder(
        servingWeight: Double,
        missing: Set<FoodDraft.MandatoryNutrient>? = nil,
    ) throws -> FoodDetail {
        guard servingWeight > 0, servingWeight.isFinite else { throw ServingWeightError.notPositive }
        guard Self.servingWeightRange.contains(servingWeight) else { throw ServingWeightError.outOfRange }
        let per100 = Nutrients.per100(fromServing: food.per100, servingGrams: servingWeight)
        guard per100.kcal <= NutrientLimits.maxKcalPer100 else {
            throw ServingWeightError.implausibleEnergy(kcalPer100: per100.kcal)
        }
        let macros = per100.proteinG + per100.carbsG + per100.fatG
        guard macros <= NutrientLimits.maxMacroSumPer100 else {
            throw ServingWeightError.implausibleMacros(gramsPer100: macros)
        }

        var result = self
        result.food.per100 = per100
        result.food.perServingOnly = false
        if Self.isPerServingPlaceholderNote(food.notes) {
            result.food.notes = nil
        }
        let missing = missing ?? Self.zeroMandatoryNutrients(food)
        if missing.isEmpty {
            result.food.dataQuality = .complete
        }
        result.servings = servings.map { serving in
            guard serving.id == food.defaultServingID else { return serving }
            var updated = serving
            updated.grams = servingWeight
            return updated
        }
        return result
    }

    /// Mandatory values stored as 0.
    private static func zeroMandatoryNutrients(_ food: Food) -> Set<FoodDraft.MandatoryNutrient> {
        var missing: Set<FoodDraft.MandatoryNutrient> = []
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
