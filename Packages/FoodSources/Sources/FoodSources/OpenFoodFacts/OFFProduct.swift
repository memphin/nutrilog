import Foundation

/// One Open Food Facts product as returned by `GET /api/v2/product/{code}.json?fields=…`, limited to
/// ``OFFProduct/fields``.
///
/// Decoding is lenient: OFF sends numbers as JSON numbers or strings, empty objects as `[]`, and the occasional
/// `null`. Unusable values become `nil` instead of failing the whole product. The type is `Codable` so the
/// barcode pipeline can cache it (SPEC §9) and decode it again; it encodes with OFF's own key names.
public struct OFFProduct: Hashable, Sendable, Codable {
    /// Barcode as OFF knows it.
    public var code: String
    /// Name in the product's main language (what is printed on the pack).
    public var productName: String?
    public var productNameHR: String?
    public var productNameEN: String?
    public var genericName: String?
    /// Comma-separated brand list, e.g. "Kraš,Kraš d.d.".
    public var brands: String?
    /// Package size as printed, e.g. "100 g", "0,5 l".
    public var quantity: String?
    public var productQuantity: Double?
    public var productQuantityUnit: String?
    /// Serving as printed, e.g. "1 portion (30 g)", "2 keksa (25 g)".
    public var servingSize: String?
    /// Serving amount in g or ml (see ``servingQuantityUnit``) when OFF could work it out.
    public var servingQuantity: Double?
    public var servingQuantityUnit: String?
    /// "100g" or "serving": the basis the contributor typed the values in. `_100g` keys are per 100 g either way.
    public var nutritionDataPer: String?
    /// Numeric `nutriments` entries, e.g. `"energy-kcal_100g": 539`, `"salt_serving": 0.02`. Non-numeric entries
    /// (units, labels) are dropped.
    public var nutriments: [String: Double]
    public var nutriscoreGrade: String?
    public var imageFrontSmallURL: String?
    public var ingredientsText: String?
    public var allergensTags: [String]
    /// Unix seconds.
    public var lastModifiedT: Int?

    /// The `fields` allowlist sent with every product request: only what the mapper and product card use.
    public static let fields: [String] = [
        "code",
        "product_name",
        "product_name_hr",
        "product_name_en",
        "generic_name",
        "brands",
        "quantity",
        "product_quantity",
        "product_quantity_unit",
        "serving_size",
        "serving_quantity",
        "serving_quantity_unit",
        "nutrition_data_per",
        "nutriments",
        "nutriscore_grade",
        "image_front_small_url",
        "ingredients_text",
        "allergens_tags",
        "last_modified_t",
    ]

    public init(
        code: String,
        productName: String? = nil,
        productNameHR: String? = nil,
        productNameEN: String? = nil,
        genericName: String? = nil,
        brands: String? = nil,
        quantity: String? = nil,
        productQuantity: Double? = nil,
        productQuantityUnit: String? = nil,
        servingSize: String? = nil,
        servingQuantity: Double? = nil,
        servingQuantityUnit: String? = nil,
        nutritionDataPer: String? = nil,
        nutriments: [String: Double] = [:],
        nutriscoreGrade: String? = nil,
        imageFrontSmallURL: String? = nil,
        ingredientsText: String? = nil,
        allergensTags: [String] = [],
        lastModifiedT: Int? = nil,
    ) {
        self.code = code
        self.productName = productName
        self.productNameHR = productNameHR
        self.productNameEN = productNameEN
        self.genericName = genericName
        self.brands = brands
        self.quantity = quantity
        self.productQuantity = productQuantity
        self.productQuantityUnit = productQuantityUnit
        self.servingSize = servingSize
        self.servingQuantity = servingQuantity
        self.servingQuantityUnit = servingQuantityUnit
        self.nutritionDataPer = nutritionDataPer
        self.nutriments = nutriments
        self.nutriscoreGrade = nutriscoreGrade
        self.imageFrontSmallURL = imageFrontSmallURL
        self.ingredientsText = ingredientsText
        self.allergensTags = allergensTags
        self.lastModifiedT = lastModifiedT
    }

    public var lastModified: Date? {
        lastModifiedT.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    enum CodingKeys: String, CodingKey {
        case code, brands, quantity, nutriments
        case productName = "product_name"
        case productNameHR = "product_name_hr"
        case productNameEN = "product_name_en"
        case genericName = "generic_name"
        case productQuantity = "product_quantity"
        case productQuantityUnit = "product_quantity_unit"
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case servingQuantityUnit = "serving_quantity_unit"
        case nutritionDataPer = "nutrition_data_per"
        case nutriscoreGrade = "nutriscore_grade"
        case imageFrontSmallURL = "image_front_small_url"
        case ingredientsText = "ingredients_text"
        case allergensTags = "allergens_tags"
        case lastModifiedT = "last_modified_t"
    }

    /// Throws only when the product is not a JSON object at all; every field is read leniently.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = container.lenientString(.code) ?? ""
        productName = container.lenientString(.productName)
        productNameHR = container.lenientString(.productNameHR)
        productNameEN = container.lenientString(.productNameEN)
        genericName = container.lenientString(.genericName)
        brands = container.lenientString(.brands)
        quantity = container.lenientString(.quantity)
        productQuantity = container.lenientDouble(.productQuantity)
        productQuantityUnit = container.lenientString(.productQuantityUnit)
        servingSize = container.lenientString(.servingSize)
        servingQuantity = container.lenientDouble(.servingQuantity)
        servingQuantityUnit = container.lenientString(.servingQuantityUnit)
        nutritionDataPer = container.lenientString(.nutritionDataPer)
        nutriments = (try? container.decodeIfPresent(LenientNutriments.self, forKey: .nutriments))?.values ?? [:]
        nutriscoreGrade = container.lenientString(.nutriscoreGrade)
        imageFrontSmallURL = container.lenientString(.imageFrontSmallURL)
        ingredientsText = container.lenientString(.ingredientsText)
        allergensTags = container.lenientStrings(.allergensTags)
        lastModifiedT = container.lenientDouble(.lastModifiedT).flatMap { Int(exactly: $0.rounded()) }
    }
}

/// `nutriments` object: keeps every entry that reads as a finite number. A non-object (OFF sends `[]` for an
/// empty object) yields no values.
private struct LenientNutriments: Decodable {
    let values: [String: Double]

    init(from decoder: any Decoder) {
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self) else {
            values = [:]
            return
        }
        var values: [String: Double] = [:]
        for key in container.allKeys {
            if let value = container.lenientDouble(key) {
                values[key.stringValue] = value
            }
        }
        self.values = values
    }
}

/// Envelope of a v2 product response: `{"code": "…", "status": 1, "status_verbose": "…", "product": {…}}`.
struct OFFProductResponse: Decodable {
    /// 1 = found, 0 = not found. `nil` when absent or unreadable.
    let status: Int?
    let code: String?
    let product: OFFProduct?

    enum CodingKeys: String, CodingKey {
        case status, code, product
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lenientDouble(.status).flatMap { Int(exactly: $0) }
        code = container.lenientString(.code)
        product = try? container.decodeIfPresent(OFFProduct.self, forKey: .product)
    }

    /// `nil` when `data` isn't a JSON object.
    static func parse(_ data: Data) -> OFFProductResponse? {
        try? JSONDecoder().decode(OFFProductResponse.self, from: data)
    }
}
