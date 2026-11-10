import Core
import Foundation
import FoundationModels
import OSLog
import UIKit

/// ``MealEstimating`` with the on-device Apple Intelligence model (Foundation Models). Nothing leaves the phone and
/// there is no account or key. Text works from iOS 26; a photo needs the model's vision capability (iOS 27).
struct AppleMealEstimator: MealEstimating {
    @Generable(description: "The foods and drinks of one meal")
    struct Meal {
        @Guide(description: "Each distinct food or drink. Empty when the input shows or names no food.")
        var items: [Item]
    }

    @Generable(description: "One food or drink of the meal")
    struct Item {
        @Guide(description: "Short name, as written in a food diary")
        var name: String
        @Guide(description: "Estimated amount in grams, or millilitres for a drink")
        var grams: Double
        @Guide(description: "Kilocalories of that whole amount")
        var kcal: Double
        @Guide(description: "Grams of protein in that whole amount")
        var proteinG: Double
        @Guide(description: "Grams of carbohydrate in that whole amount")
        var carbsG: Double
        @Guide(description: "Grams of fat in that whole amount")
        var fatG: Double
    }

    static let instructions = """
    You estimate what a meal contains for a food diary. The user sends a photo of food, a short description, or both.

    List each distinct food or drink as its own item, with your best estimate of its amount in grams (millilitres \
    for drinks) and the energy and macronutrients of that whole amount. The diary's owner corrects the amounts \
    afterwards, so commit to one realistic estimate per item: use typical portion sizes and visible cues such as \
    the plate and cutlery for scale. When the description gives an amount, use it. Include cooking fat, sauces and \
    dressings that you can see or that the dish normally contains.

    Name each item briefly, in the language of the description, or in English when there is only a photo. If \
    nothing in the input is food or drink, return no items.
    """

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // The iOS 27 APIs below (`capabilities`, `Attachment`, `LanguageModelError`) exist only in the iOS 27 SDK
    // (Xcode 27, Swift 6.4). `#available` is a runtime check, so they are also gated at compile time to keep the
    // app building with the iOS 26 SDK; such a build estimates from text only.
    var supportsPhotos: Bool {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return false }
        return isAvailable && SystemLanguageModel.default.capabilities.contains(.vision)
        #else
        return false
        #endif
    }

    func estimate(_ request: MealEstimateRequest) async throws -> [EstimatedFood] {
        guard isAvailable else { throw MealEstimateError.unavailable }
        let photo = supportsPhotos ? request.jpeg.flatMap { UIImage(data: $0)?.cgImage } : nil
        guard photo != nil || request.trimmedText != nil else { throw MealEstimateError.noFood }
        let text = request.trimmedText ?? "Estimate the meal in this photo."

        let session = LanguageModelSession(instructions: Self.instructions)
        let meal: Meal
        do {
            #if compiler(>=6.4)
            if let photo, #available(iOS 27.0, *) {
                meal = try await session.respond(generating: Meal.self) {
                    Attachment(photo)
                    text
                }.content
            } else {
                meal = try await session.respond(to: text, generating: Meal.self).content
            }
            #else
            meal = try await session.respond(to: text, generating: Meal.self).content
            #endif
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger(subsystem: "hr.ivanjuric.nutrilog", category: "smart-log").error("Meal estimate failed: \(String(describing: error))")
            throw Self.isRefusal(error) ? MealEstimateError.refused : MealEstimateError.failed
        }

        let foods = meal.items.compactMap {
            EstimatedFood(
                name: $0.name, grams: $0.grams, totalKcal: $0.kcal, totalProteinG: $0.proteinG, totalCarbsG: $0.carbsG,
                totalFatG: $0.fatG,
            )
        }
        guard !foods.isEmpty else { throw MealEstimateError.noFood }
        return foods
    }

    private static func isRefusal(_ error: any Error) -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: return false
            }
        }
        #endif
        if case LanguageModelSession.GenerationError.guardrailViolation = error {
            return true
        }
        return false
    }
}

/// No model: tests and previews. Smart log then matches against the foods on the phone.
struct NoMealEstimator: MealEstimating {
    var isAvailable: Bool {
        false
    }

    var supportsPhotos: Bool {
        false
    }

    func estimate(_: MealEstimateRequest) async throws -> [EstimatedFood] {
        throw MealEstimateError.unavailable
    }
}
