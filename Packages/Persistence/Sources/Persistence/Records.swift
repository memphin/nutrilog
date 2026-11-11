import Core
import Foundation
import GRDB

// MARK: - Food

public enum FoodSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case custom, off, usda, bundled
    /// Legacy: recipes were removed in favour of saved meals (issue #68). Migration 008 and the JSON import turn
    /// recipe foods into `custom` ones, so nothing writes this value any more; the case stays so old rows and old
    /// exports still decode. Treat it like `custom`.
    case recipe
}

public enum DataQuality: String, Codable, Sendable, DatabaseValueConvertible {
    case complete
    case partialMacros = "partial_macros"
    case energyOnly = "energy_only"
}

public struct Food: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "food"

    public var id: String
    public var name: String
    public var nameLocal: String?
    public var brand: String?
    public var source: FoodSource
    public var sourceID: String?
    public var kcal100: Double
    public var proteinG100: Double
    public var carbsG100: Double
    public var fatG100: Double
    public var fiberG100: Double?
    public var sugarG100: Double?
    public var satFatG100: Double?
    public var sodiumMg100: Double?
    public var microsJSON: String?
    public var isLiquid: Bool
    public var defaultServingID: String?
    public var imageURL: String?
    public var nutriscore: String?
    public var dataQuality: DataQuality
    public var isFavorite: Bool
    public var useCount: Int
    public var lastUsedAt: Date?
    public var notes: String?
    public var cookedWeightG: Double?
    public var servingsCount: Double?
    public var lastServingID: String?
    public var lastAmount: Double?
    /// The per-100 values are really the values of one serving whose weight is unknown (a copy of a per-serving-only
    /// online food); the default serving is a stand-in of 100 g/ml. See ``FoodDetail/isPerServingPlaceholder``.
    public var perServingOnly: Bool
    /// Set on a food merged away into another (Settings → Duplicate foods): the id of the food it was merged into,
    /// which may itself have been merged later (see `FoodRepository.mergeKeeper`). nil for every other food.
    public var mergedIntoID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name, brand, source, notes, nutriscore, revision
        case nameLocal = "name_local"
        case sourceID = "source_id"
        case kcal100 = "kcal_100"
        case proteinG100 = "protein_g_100"
        case carbsG100 = "carbs_g_100"
        case fatG100 = "fat_g_100"
        case fiberG100 = "fiber_g_100"
        case sugarG100 = "sugar_g_100"
        case satFatG100 = "sat_fat_g_100"
        case sodiumMg100 = "sodium_mg_100"
        case microsJSON = "micros_json"
        case isLiquid = "is_liquid"
        case defaultServingID = "default_serving_id"
        case imageURL = "image_url"
        case dataQuality = "data_quality"
        case isFavorite = "is_favorite"
        case useCount = "use_count"
        case lastUsedAt = "last_used_at"
        case cookedWeightG = "cooked_weight_g"
        case servingsCount = "servings_count"
        case lastServingID = "last_serving_id"
        case lastAmount = "last_amount"
        case perServingOnly = "per_serving_only"
        case mergedIntoID = "merged_into_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(
        id: String = newID(),
        name: String,
        nameLocal: String? = nil,
        brand: String? = nil,
        source: FoodSource = .custom,
        sourceID: String? = nil,
        per100: Nutrients,
        isLiquid: Bool = false,
        dataQuality: DataQuality = .complete,
        notes: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.nameLocal = nameLocal
        self.brand = brand
        self.source = source
        self.sourceID = sourceID
        kcal100 = per100.kcal
        proteinG100 = per100.proteinG
        carbsG100 = per100.carbsG
        fatG100 = per100.fatG
        fiberG100 = per100.fiberG
        sugarG100 = per100.sugarG
        satFatG100 = per100.satFatG
        sodiumMg100 = per100.sodiumMg
        self.isLiquid = isLiquid
        self.dataQuality = dataQuality
        isFavorite = false
        useCount = 0
        perServingOnly = false
        self.notes = notes
        let now = Date()
        createdAt = now
        updatedAt = now
        revision = 1
    }

    /// Nutrients per 100 g (or ml).
    public var per100: Nutrients {
        get {
            Nutrients(
                kcal: kcal100, proteinG: proteinG100, carbsG: carbsG100, fatG: fatG100,
                fiberG: fiberG100, sugarG: sugarG100, satFatG: satFatG100, sodiumMg: sodiumMg100,
            )
        }
        set {
            kcal100 = newValue.kcal
            proteinG100 = newValue.proteinG
            carbsG100 = newValue.carbsG
            fatG100 = newValue.fatG
            fiberG100 = newValue.fiberG
            sugarG100 = newValue.sugarG
            satFatG100 = newValue.satFatG
            sodiumMg100 = newValue.sodiumMg
        }
    }

    public var baseUnit: BaseUnit {
        BaseUnit(isLiquid: isLiquid)
    }

    /// "Name · Brand" for lists.
    public var displayName: String {
        if let brand, !brand.isEmpty {
            return "\(name) · \(brand)"
        }
        return name
    }
}

public struct Serving: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "serving"

    public var id: String
    public var foodID: String
    public var label: String
    /// Amount in the food's base unit (g or ml).
    public var grams: Double
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, label, grams, revision
        case foodID = "food_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(id: String = newID(), foodID: String = "", label: String, grams: Double, sortOrder: Int = 0) {
        self.id = id
        self.foodID = foodID
        self.label = label
        self.grams = grams
        self.sortOrder = sortOrder
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }

    public var size: ServingSize {
        ServingSize(label: label, amount: grams)
    }
}

public struct FoodBarcode: Codable, Hashable, Sendable, TimestampedRecord {
    public static let databaseTableName = "food_barcode"

    public var barcode: String
    public var foodID: String
    public var createdAt: Date

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case barcode
        case foodID = "food_id"
        case createdAt = "created_at"
    }

    public typealias Columns = CodingKeys
}

/// A food with its servings and barcodes — what the edit form and quantity sheet work with.
public struct FoodDetail: Hashable, Sendable {
    public var food: Food
    public var servings: [Serving]
    public var barcodes: [String]

    public init(food: Food, servings: [Serving] = [], barcodes: [String] = []) {
        self.food = food
        self.servings = servings
        self.barcodes = barcodes
    }

    /// True for a copy of a per-serving-only online food: its values are per serving with an unknown serving weight
    /// and its default serving is a 100 g/ml stand-in. Log it by servings only (hide gram entry) and offer to set the
    /// real serving weight.
    public var isPerServingPlaceholder: Bool {
        food.perServingOnly && food.defaultServingID.map { id in servings.contains { $0.id == id } } == true
    }

    /// The quantity to prefill: last used, else the default serving, else 100 g/ml.
    public var suggestedQuantity: Quantity {
        if let id = food.lastServingID, let serving = servings.first(where: { $0.id == id }) {
            return .servings(count: food.lastAmount ?? 1, serving: serving.size)
        }
        if food.lastServingID == nil, let amount = food.lastAmount, amount > 0 {
            return .base(amount)
        }
        if let id = food.defaultServingID, let serving = servings.first(where: { $0.id == id }) {
            return .servings(count: 1, serving: serving.size)
        }
        return .base(100)
    }
}

// MARK: - Diary

public struct MealSlot: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "meal_slot"

    public var id: String
    public var name: String
    public var sortOrder: Int
    public var defaultStartHour: Int?
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, name, revision
        case sortOrder = "sort_order"
        case defaultStartHour = "default_start_hour"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(id: String = newID(), name: String, sortOrder: Int, defaultStartHour: Int? = nil, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.defaultStartHour = defaultStartHour
        self.isActive = isActive
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }
}

public struct DiaryEntry: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "diary_entry"

    public var id: String
    public var day: LocalDay
    public var mealSlotID: String
    public var foodID: String?
    public var displayName: String
    /// Amount in the food's base unit (g or ml); 0 for quick-add.
    public var grams: Double
    public var servingLabel: String?
    public var isQuickAdd: Bool
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double?
    public var sugarG: Double?
    public var satFatG: Double?
    public var sodiumMg: Double?
    public var note: String?
    public var loggedAt: Date
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, day, grams, kcal, note, revision
        case mealSlotID = "meal_slot_id"
        case foodID = "food_id"
        case displayName = "display_name"
        case servingLabel = "serving_label"
        case isQuickAdd = "is_quick_add"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case satFatG = "sat_fat_g"
        case sodiumMg = "sodium_mg"
        case loggedAt = "logged_at"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    init(
        id: String = newID(), day: LocalDay, mealSlotID: String, foodID: String?, displayName: String,
        grams: Double, servingLabel: String?, isQuickAdd: Bool, nutrients: Nutrients, loggedAt: Date, sortOrder: Int,
    ) {
        self.id = id
        self.day = day
        self.mealSlotID = mealSlotID
        self.foodID = foodID
        self.displayName = displayName
        self.grams = grams
        self.servingLabel = servingLabel
        self.isQuickAdd = isQuickAdd
        kcal = nutrients.kcal
        proteinG = nutrients.proteinG
        carbsG = nutrients.carbsG
        fatG = nutrients.fatG
        fiberG = nutrients.fiberG
        sugarG = nutrients.sugarG
        satFatG = nutrients.satFatG
        sodiumMg = nutrients.sodiumMg
        self.loggedAt = loggedAt
        self.sortOrder = sortOrder
        createdAt = loggedAt
        updatedAt = loggedAt
        revision = 1
    }

    /// Nutrient snapshot taken at log time — the source of truth for history (NFR-4).
    public var nutrients: Nutrients {
        get {
            Nutrients(
                kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                fiberG: fiberG, sugarG: sugarG, satFatG: satFatG, sodiumMg: sodiumMg,
            )
        }
        set {
            kcal = newValue.kcal
            proteinG = newValue.proteinG
            carbsG = newValue.carbsG
            fatG = newValue.fatG
            fiberG = newValue.fiberG
            sugarG = newValue.sugarG
            satFatG = newValue.satFatG
            sodiumMg = newValue.sodiumMg
        }
    }
}

public struct DayNote: Codable, Hashable, Sendable, SyncedRecord {
    public static let databaseTableName = "day_note"

    public var day: LocalDay
    public var text: String
    public var isComplete: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case day, text, revision
        case isComplete = "is_complete"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

// MARK: - Body

public struct WeightEntry: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "weight_entry"

    public var id: String
    public var measuredAt: Date
    public var kg: Double
    public var bodyFatPct: Double?
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, kg, source, revision
        case measuredAt = "measured_at"
        case bodyFatPct = "body_fat_pct"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

// MARK: - Profile & targets

public struct Profile: Codable, Hashable, Sendable, TimestampedRecord {
    public static let databaseTableName = "profile"

    public var id: Int = 1
    public var heightCm: Double?
    public var birthDate: LocalDay?
    public var sex: Sex?
    public var activityLevel: ActivityLevel
    public var goalMode: GoalMode
    public var goalRateKgPerWeek: Double
    public var waterGoalMl: Double
    public var checkinWeekday: Int
    public var updatedAt: Date
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, sex, revision
        case heightCm = "height_cm"
        case birthDate = "birth_date"
        case activityLevel = "activity_level"
        case goalMode = "goal_mode"
        case goalRateKgPerWeek = "goal_rate_kg_per_week"
        case waterGoalMl = "water_goal_ml"
        case checkinWeekday = "checkin_weekday"
        case updatedAt = "updated_at"
    }

    /// True when everything needed for the Mifflin-St Jeor formula is known (weight comes separately).
    public var isCompleteForFormula: Bool {
        heightCm != nil && birthDate != nil && sex != nil
    }
}

public enum TargetOrigin: String, Codable, Sendable, DatabaseValueConvertible {
    case manual, formula, adaptive
}

public struct Target: Codable, Hashable, Identifiable, Sendable, SyncedRecord {
    public static let databaseTableName = "target"

    public var id: String
    public var effectiveFrom: LocalDay
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double?
    public var weekdayOverridesJSON: String?
    public var origin: TargetOrigin
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, kcal, origin, revision
        case effectiveFrom = "effective_from"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case weekdayOverridesJSON = "weekday_overrides_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public init(
        id: String = newID(), effectiveFrom: LocalDay, kcal: Double, macros: MacroTargets,
        fiberG: Double? = nil, origin: TargetOrigin,
    ) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.kcal = kcal
        proteinG = macros.proteinG
        carbsG = macros.carbsG
        fatG = macros.fatG
        self.fiberG = fiberG
        self.origin = origin
        createdAt = Date()
        updatedAt = createdAt
        revision = 1
    }

    public var macros: MacroTargets {
        MacroTargets(proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }
}

// MARK: - Settings

struct SettingRow: Codable, Sendable, TimestampedRecord {
    static let databaseTableName = "setting"

    var key: String
    var value: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
    }
}
