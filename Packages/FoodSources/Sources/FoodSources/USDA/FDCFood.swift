import Foundation

/// One food in an FDC `/v1/foods/search` result ("abridged" search format), with only the fields we use.
///
/// Decoding never fails: missing or malformed fields are `nil`, so one odd record can't break a whole result page.
public struct FDCFood: Hashable, Sendable, Codable {
    /// FDC ID; foods without one are dropped by ``FDCFoodMapper``.
    public var fdcId: Int?
    /// FDC `description`: the food's name, e.g. "Apples, fuji, with skin, raw" or "CHEDDAR CHEESE" (Branded).
    public var name: String?
    /// "Foundation", "SR Legacy", "Branded", "Survey (FNDDS)".
    public var dataType: String?
    public var gtinUpc: String?
    public var brandOwner: String?
    public var brandName: String?
    /// Branded: serving amount in ``servingSizeUnit``.
    public var servingSize: Double?
    /// Branded: "g", "ml", "GRM", "MLT", …
    public var servingSizeUnit: String?
    /// Branded: serving as printed, e.g. "1 cup", "1 ONZ".
    public var householdServingFullText: String?
    /// Values per 100 g (Branded: per 100 g or 100 ml, by ``servingSizeUnit``).
    public var foodNutrients: [FDCNutrient]

    public init(
        fdcId: Int?,
        name: String?,
        dataType: String? = nil,
        gtinUpc: String? = nil,
        brandOwner: String? = nil,
        brandName: String? = nil,
        servingSize: Double? = nil,
        servingSizeUnit: String? = nil,
        householdServingFullText: String? = nil,
        foodNutrients: [FDCNutrient] = [],
    ) {
        self.fdcId = fdcId
        self.name = name
        self.dataType = dataType
        self.gtinUpc = gtinUpc
        self.brandOwner = brandOwner
        self.brandName = brandName
        self.servingSize = servingSize
        self.servingSizeUnit = servingSizeUnit
        self.householdServingFullText = householdServingFullText
        self.foodNutrients = foodNutrients
    }

    enum CodingKeys: String, CodingKey {
        case fdcId, dataType, gtinUpc, brandOwner, brandName, servingSize, servingSizeUnit
        case householdServingFullText, foodNutrients
        case name = "description"
    }

    public init(from decoder: any Decoder) {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(fdcId: nil, name: nil)
            return
        }
        self.init(
            fdcId: container.lenientDouble(.fdcId).flatMap { Int(exactly: $0) },
            name: container.lenientString(.name),
            dataType: container.lenientString(.dataType),
            gtinUpc: container.lenientString(.gtinUpc),
            brandOwner: container.lenientString(.brandOwner),
            brandName: container.lenientString(.brandName),
            servingSize: container.lenientDouble(.servingSize),
            servingSizeUnit: container.lenientString(.servingSizeUnit),
            householdServingFullText: container.lenientString(.householdServingFullText),
            foodNutrients: (try? container.decodeIfPresent([FDCNutrient].self, forKey: .foodNutrients)) ?? [],
        )
    }
}

/// One nutrient amount of an ``FDCFood``, as the search endpoint reports it.
public struct FDCNutrient: Hashable, Sendable, Codable {
    /// FDC nutrient ID, e.g. 1008 (energy, kcal).
    public var nutrientId: Int?
    /// Legacy SR nutrient number, e.g. "208"; used when ``nutrientId`` is absent.
    public var nutrientNumber: String?
    public var nutrientName: String?
    /// "G", "MG", "UG", "KCAL", "kJ", "IU", …
    public var unitName: String?
    public var value: Double?

    public init(nutrientId: Int?, nutrientNumber: String? = nil, nutrientName: String? = nil, unitName: String?, value: Double?) {
        self.nutrientId = nutrientId
        self.nutrientNumber = nutrientNumber
        self.nutrientName = nutrientName
        self.unitName = unitName
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case nutrientId, nutrientNumber, nutrientName, unitName, value
    }

    public init(from decoder: any Decoder) {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(nutrientId: nil, unitName: nil, value: nil)
            return
        }
        self.init(
            nutrientId: container.lenientDouble(.nutrientId).flatMap { Int(exactly: $0) },
            nutrientNumber: container.lenientString(.nutrientNumber),
            nutrientName: container.lenientString(.nutrientName),
            unitName: container.lenientString(.unitName),
            value: container.lenientDouble(.value),
        )
    }
}

/// The body of `/v1/foods/search`.
struct FDCSearchResponse: Decodable {
    var totalHits: Int?
    var foods: [FDCFood]

    enum CodingKeys: String, CodingKey {
        case totalHits, foods
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalHits = container.lenientDouble(.totalHits).flatMap { Int(exactly: $0) }
        foods = try container.decode([FDCFood].self, forKey: .foods)
    }

    /// `nil` unless `data` is a JSON object with a `foods` array.
    static func parse(_ data: Data) -> FDCSearchResponse? {
        try? JSONDecoder().decode(FDCSearchResponse.self, from: data)
    }
}

/// The api.data.gov error body: `{"error": {"code": "API_KEY_INVALID", "message": "…"}}`.
struct FDCErrorResponse: Decodable {
    struct Detail: Decodable {
        var code: String?
    }

    var error: Detail?

    static func code(in data: Data) -> String? {
        (try? JSONDecoder().decode(FDCErrorResponse.self, from: data))?.error?.code
    }
}
