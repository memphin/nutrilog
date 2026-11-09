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
    static let perServingFallbackLabel = "1 serving"

    /// Note stored on a copy whose values are per serving and whose source gives no serving weight.
    static let perServingUnknownWeightNote =
        "Nutrition per serving; the serving weight is unknown, so 1 serving is counted as 100 g/ml."

    /// Note stored on a copy whose values are per serving and whose serving weight (e.g. "0.5 g") is too small, or
    /// gives implausible per-100 values, to convert with.
    static func perServingUnusableWeightNote(_ size: ServingSize, isLiquid: Bool) -> String {
        let weight = "\(NumberFormatting.compact(size.amount)) \(BaseUnit(isLiquid: isLiquid).symbol)"
        return "Nutrition per serving; the serving weight given (\(weight)) can't be used to work out values per 100, "
            + "so 1 serving is counted as 100 g/ml."
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
            if let size = draft.serving, size.amount > 0, size.amount.isFinite {
                serving = Serving(label: size.label, grams: size.amount)
            }
        case .perServing:
            let label = draft.servingDescription ?? draft.serving?.label ?? Self.perServingFallbackLabel
            serving = Serving(label: label, grams: 100)
            food.perServingOnly = true
            if let size = draft.serving, size.amount > 0, size.amount.isFinite {
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
