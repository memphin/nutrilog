import Core
import Foundation

/// How much of a food's nutrition is known. Raw values match `Persistence.DataQuality`, so the app converts with
/// `DataQuality(rawValue: quality.rawValue)` (FoodSources does not depend on Persistence).
public enum FoodDataQuality: String, Hashable, Sendable, Codable, CaseIterable {
    /// Energy, protein, carbs and fat per 100 g/ml are all known.
    case complete
    /// Something is missing: a macro, the energy, or the serving size of per-serving-only values.
    case partialMacros = "partial_macros"
    /// Energy is known, protein, carbs and fat are all missing.
    case energyOnly = "energy_only"
}

/// A food read from an online source, not yet saved. The barcode pipeline (#19) and online search (#22) turn it
/// into a `Persistence.Food` + servings + barcode.
public struct FoodDraft: Hashable, Sendable, Codable {
    /// Where the food came from. Raw values match `Persistence.FoodSource`.
    public enum Origin: String, Hashable, Sendable, Codable {
        case off, usda
    }

    /// What ``FoodDraft/nutrients`` are relative to.
    public enum NutrientBasis: Hashable, Sendable, Codable {
        /// Per 100 g (or 100 ml for liquids) — the normal case.
        case per100
        /// Per one serving whose weight is unknown (``FoodDraft/servingDescription`` says what a serving is).
        /// Only produced when no per-100 value could be derived; data quality is then `.partialMacros`.
        case perServing
    }

    /// The four nutrients a `Food` cannot leave out.
    public enum MandatoryNutrient: String, Hashable, Sendable, Codable, CaseIterable {
        case energy, protein, carbs, fat
    }

    public var origin: Origin
    /// ID in the source: the OFF code, the FDC ID.
    public var sourceID: String
    /// Barcode to link the food to, when the source is barcode-based.
    public var barcode: String?
    /// Display name. `nil` when the source has none — the caller decides what to show.
    public var name: String?
    /// Croatian name when it differs from ``name``.
    public var nameLocal: String?
    public var brand: String?
    /// Values per ``basis``. Missing mandatory values are 0 and listed in ``missingNutrients``.
    public var nutrients: Nutrients
    public var basis: NutrientBasis
    public var missingNutrients: Set<MandatoryNutrient>
    public var isLiquid: Bool
    /// Default serving with its amount in the base unit (g or ml), when known.
    public var serving: ServingSize?
    /// Serving as printed by the source, e.g. "1 bar", even when its weight is unknown.
    public var servingDescription: String?
    /// Package size as printed, e.g. "100 g".
    public var packageDescription: String?
    public var imageURL: URL?
    /// Nutri-Score grade "a"…"e", lowercase; `nil` when unknown or not applicable.
    public var nutriscore: String?
    /// Page to link back to (ODbL attribution, SPEC §3.1).
    public var productURL: URL?
    public var ingredientsText: String?
    /// Source tags as given, e.g. "en:milk".
    public var allergens: [String]
    public var lastModified: Date?

    public init(
        origin: Origin,
        sourceID: String,
        barcode: String? = nil,
        name: String?,
        nameLocal: String? = nil,
        brand: String? = nil,
        nutrients: Nutrients,
        basis: NutrientBasis = .per100,
        missingNutrients: Set<MandatoryNutrient> = [],
        isLiquid: Bool = false,
        serving: ServingSize? = nil,
        servingDescription: String? = nil,
        packageDescription: String? = nil,
        imageURL: URL? = nil,
        nutriscore: String? = nil,
        productURL: URL? = nil,
        ingredientsText: String? = nil,
        allergens: [String] = [],
        lastModified: Date? = nil,
    ) {
        self.origin = origin
        self.sourceID = sourceID
        self.barcode = barcode
        self.name = name
        self.nameLocal = nameLocal
        self.brand = brand
        self.nutrients = nutrients
        self.basis = basis
        self.missingNutrients = missingNutrients
        self.isLiquid = isLiquid
        self.serving = serving
        self.servingDescription = servingDescription
        self.packageDescription = packageDescription
        self.imageURL = imageURL
        self.nutriscore = nutriscore
        self.productURL = productURL
        self.ingredientsText = ingredientsText
        self.allergens = allergens
        self.lastModified = lastModified
    }

    /// Data-quality rule (SPEC §9): per-serving values without a serving weight are partial; otherwise complete
    /// when nothing is missing, energy-only when all three macros are missing, partial for anything else.
    public static func classify(basis: NutrientBasis, missing: Set<MandatoryNutrient>) -> FoodDataQuality {
        if basis == .perServing {
            return .partialMacros
        }
        if missing.isEmpty {
            return .complete
        }
        if missing == [.protein, .carbs, .fat] {
            return .energyOnly
        }
        return .partialMacros
    }

    /// Derived from ``basis`` and ``missingNutrients`` by ``classify(basis:missing:)``.
    public var dataQuality: FoodDataQuality {
        Self.classify(basis: basis, missing: missingNutrients)
    }

    public var baseUnit: BaseUnit {
        BaseUnit(isLiquid: isLiquid)
    }
}
