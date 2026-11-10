import Foundation

/// One food of a meal estimated from a photo or a description: a name, an amount and the values for 100 g.
/// The amount can be changed afterwards; the nutrients follow it.
public struct EstimatedFood: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Amount in grams (ml for drinks).
    public var grams: Double
    public var per100: Nutrients

    public init(id: UUID = UUID(), name: String, grams: Double, per100: Nutrients) {
        self.id = id
        self.name = name
        self.grams = grams
        self.per100 = per100
    }

    /// Nutrients of the whole amount.
    public var nutrients: Nutrients {
        per100.scaled(toGrams: grams)
    }
}

extension EstimatedFood {
    /// From a model's answer, where the energy and macros are for the whole amount. Nil without a name, without a
    /// positive amount or with a non-finite value; negative values count as zero.
    public init?(name: String, grams: Double, totalKcal: Double, totalProteinG: Double, totalCarbsG: Double, totalFatG: Double) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [grams, totalKcal, totalProteinG, totalCarbsG, totalFatG]
        guard !name.isEmpty, values.allSatisfy(\.isFinite), grams > 0 else { return nil }
        let total = Nutrients(
            kcal: max(totalKcal, 0), proteinG: max(totalProteinG, 0), carbsG: max(totalCarbsG, 0), fatG: max(totalFatG, 0),
        )
        self.init(name: name, grams: grams, per100: total.scaled(by: 100 / grams))
    }
}

/// What to estimate: a photo of the meal, a description, or both.
public struct MealEstimateRequest: Sendable {
    public var text: String?
    /// JPEG data of the photo.
    public var jpeg: Data?

    public init(text: String? = nil, jpeg: Data? = nil) {
        self.text = text
        self.jpeg = jpeg
    }

    public var trimmedText: String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MealEstimateError: Error, Equatable, Sendable {
    /// No model on this device (not eligible, Apple Intelligence off, or still downloading).
    case unavailable
    /// The model declined the request.
    case refused
    /// The answer held no food: nothing recognisable in the photo or the text.
    case noFood
    case failed
}

/// Turns a photo or a description of a meal into foods with amounts and nutrients.
public protocol MealEstimating: Sendable {
    /// Whether ``estimate(_:)`` can run right now.
    var isAvailable: Bool { get }
    /// Whether a photo can be part of the request; false means text only.
    var supportsPhotos: Bool { get }
    func estimate(_ request: MealEstimateRequest) async throws -> [EstimatedFood]
}

/// Splits a typed meal ("2 eggs, 150 g rice and a banana") into foods with an amount, for matching against the
/// foods on the phone when no online estimate is available.
public enum MealDescription {
    public struct Part: Hashable, Sendable {
        /// The food words, without the amount.
        public var food: String
        /// Amount in grams or ml, when the text gave one ("150 g", "2 dl").
        public var grams: Double?
        /// How many pieces, when the text gave a count instead ("2 eggs", "a banana"). 1 when nothing was said.
        public var count: Double

        public init(food: String, grams: Double? = nil, count: Double = 1) {
            self.food = food
            self.grams = grams
            self.count = count
        }
    }

    private static let units: [String: Double] = [
        "g": 1, "gr": 1, "gram": 1, "grams": 1, "kg": 1000, "dag": 10, "dkg": 10,
        "ml": 1, "cl": 10, "dl": 100, "l": 1000,
    ]
    private static let words: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "half": 0.5,
    ]

    public static func parts(_ text: String) -> [Part] {
        // A comma between digits is a decimal comma ("0,5 kg"), not a separator.
        var pieces = [text.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d)"#, with: ".", options: .regularExpression)]
        for separator in [",", ";", "\n", "+", " and ", " with ", " i ", " s ", " sa "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces.compactMap(part)
    }

    private static func part(_ text: String) -> Part? {
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return nil }
        var grams: Double?
        var count = 1.0

        if let (number, unit) = numberAndUnit(first) {
            tokens.removeFirst()
            if let unit {
                grams = number * unit
            } else if let next = tokens.first, let factor = units[next] {
                tokens.removeFirst()
                grams = number * factor
            } else {
                count = number
            }
        } else if let number = words[first], tokens.count > 1 {
            tokens.removeFirst()
            count = number
        }
        if tokens.first == "of" || tokens.first == "x" {
            tokens.removeFirst()
        }
        let food = tokens.joined(separator: " ").trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !food.isEmpty, grams ?? 1 > 0, count > 0 else { return nil }
        return Part(food: food, grams: grams, count: count)
    }

    /// "150", "1.5", "1,5", "150g", "2dl" → the number and, when glued on, the unit's grams.
    private static func numberAndUnit(_ token: String) -> (Double, Double?)? {
        let digits = token.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !digits.isEmpty, let number = Double(digits.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let rest = String(token.dropFirst(digits.count))
        if rest.isEmpty {
            return (number, nil)
        }
        guard let factor = units[rest] else { return nil }
        return (number, factor)
    }
}
