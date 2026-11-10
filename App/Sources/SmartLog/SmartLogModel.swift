import Core
import Foundation
import Persistence

/// Names what a photo shows ("banana", "pizza"), most likely first. On the phone only.
protocol FoodImageLabeling: Sendable {
    func labels(jpeg: Data) async throws -> [String]
}

/// Recognises nothing: tests and previews.
struct NoFoodImageLabeler: FoodImageLabeling {
    func labels(jpeg _: Data) async throws -> [String] {
        []
    }
}

/// Matches a description or photo labels against the foods on the phone (own foods and the bundled index). The
/// fallback where the Apple Intelligence model isn't available: it only finds foods that are already there and
/// guesses no portions.
struct OnDeviceMealMatcher {
    let search: FoodSearch
    let foods: FoodRepository

    /// Labels that say "this is food" without saying which, or that name what the food sits on.
    private static let vagueLabels: Set<String> = [
        "food", "meal", "dish", "cuisine", "fruit", "vegetable", "produce", "drink", "beverage", "liquid", "plate",
        "bowl", "cup", "glass", "table", "tableware", "cutlery", "fork", "knife", "spoon", "utensil", "kitchen",
    ]

    struct Match {
        var lines: [SmartLogModel.Line] = []
        var unmatched: [String] = []
    }

    func match(text: String) throws -> Match {
        var match = Match()
        for part in MealDescription.parts(text) {
            if let line = try line(for: part) {
                match.lines.append(line)
            } else {
                match.unmatched.append(part.food)
            }
        }
        return match
    }

    func match(labels: [String]) throws -> Match {
        var match = Match()
        for label in labels where !Self.vagueLabels.contains(label.lowercased()) && match.lines.count < 5 {
            guard let line = try line(for: .init(food: label)),
                  !match.lines.contains(where: { $0.name == line.name })
            else { continue }
            match.lines.append(line)
        }
        return match
    }

    private func line(for part: MealDescription.Part) throws -> SmartLogModel.Line? {
        guard let result = try best(part.food) else { return nil }
        var unit = BaseUnit.grams
        var typical = 100.0
        if case let .food(food) = result {
            unit = food.baseUnit
            // The amount last logged, else the default serving, else the first serving, else 100.
            if let detail = try foods.detail(id: food.id) {
                let neverLogged = food.lastAmount == nil && food.defaultServingID == nil
                typical = neverLogged ? detail.servings.first?.grams ?? 100 : detail.suggestedQuantity.baseAmount
            }
        }
        return SmartLogModel.Line(
            name: result.name, grams: part.grams ?? typical * part.count, per100: result.per100, unit: unit, origin: .local(result),
        )
    }

    /// The best search hit. Search matches word prefixes, so "egg" also finds "Eggplant": a hit that holds every
    /// typed word as a whole word (ignoring a plural "s") wins over the top hit. A plural that finds nothing
    /// ("eggs") is retried in the singular.
    private func best(_ words: String) throws -> FoodSearchResult? {
        var queries = [words]
        for ending in ["es", "s"] where words.hasSuffix(ending) && words.count > ending.count + 2 {
            queries.append(String(words.dropLast(ending.count)))
        }
        let wanted = Set(Self.wordStems(words))
        var fallback: FoodSearchResult?
        for query in queries {
            let hits = try search.search(query, limit: 20)
            if let exact = hits.first(where: { wanted.isSubset(of: Self.wordStems($0.name)) }) {
                return exact
            }
            fallback = fallback ?? hits.first
        }
        return fallback
    }

    /// Lowercased words without diacritics and without a plural "s".
    private static func wordStems(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }
}

/// "Snap or describe a meal": turns a photo or a sentence into a list of foods with amounts to review and log.
/// The estimate comes from the on-device Apple Intelligence model; where that isn't available, from the foods on
/// the phone. Nothing leaves the phone either way.
@MainActor
@Observable
final class SmartLogModel {
    enum Phase: Equatable {
        case input, working, review
    }

    enum Origin: Hashable {
        /// Estimated by the model: logged as a quick-add entry with its own values.
        case estimate
        /// A food on the phone: logged as that food.
        case local(FoodSearchResult)
    }

    struct Line: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var amountText: String
        let per100: Nutrients
        let unit: BaseUnit
        let origin: Origin

        init(name: String, grams: Double, per100: Nutrients, unit: BaseUnit = .grams, origin: Origin) {
            self.name = name
            amountText = Format.field(grams.rounded())
            self.per100 = per100
            self.unit = unit
            self.origin = origin
        }

        var grams: Double? {
            Format.number(amountText).flatMap { $0 > 0 ? $0 : nil }
        }

        var nutrients: Nutrients {
            grams.map(per100.scaled(toGrams:)) ?? .zero
        }
    }

    var text = ""
    var jpeg: Data?
    private(set) var phase = Phase.input
    var lines: [Line] = []
    /// Shown above the reviewed list: where the numbers come from and what couldn't be matched.
    private(set) var notice: String?
    var errorMessage: String?

    var canEstimate: Bool {
        phase == .input && (jpeg != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var totals: Nutrients {
        Nutrients.sum(lines.map(\.nutrients))
    }

    var canLog: Bool {
        phase == .review && !lines.isEmpty && lines.allSatisfy { $0.grams != nil }
    }

    func estimate(in environment: AppEnvironment) async {
        guard canEstimate else { return }
        phase = .working
        do {
            let result = try await Self.usesModel(environment.mealEstimator, photo: jpeg != nil, text: text)
                ? estimated(environment) : matched(environment)
            guard !Task.isCancelled else {
                phase = .input
                return
            }
            lines = result.lines
            notice = result.notice
            phase = .review
        } catch is CancellationError {
            phase = .input
        } catch {
            errorMessage = Self.message(for: error)
            phase = .input
        }
    }

    /// Back to the photo and text, keeping both.
    func editInput() {
        lines = []
        notice = nil
        phase = .input
    }

    /// Notes on a food made from an estimate, so it can be told apart and reused by a later estimate.
    static let estimatedFoodNotes = "Estimated by Apple Intelligence."

    /// Logs every line into `slotID`. Local foods are logged as themselves; an estimate becomes a food of its own
    /// (reusing one made from an identical earlier estimate), so the entry keeps its amount: tapping it edits the
    /// weight and the nutrients follow, and the meal can be saved as a meal.
    func log(slotID: String, day: LocalDay, in environment: AppEnvironment) throws {
        guard canLog, let diary = environment.diary, let foods = environment.foods else { return }
        var items: [DiaryRepository.LogItem] = []
        var estimatedFoods: [Food]?
        for line in lines {
            guard let grams = line.grams else { return }
            switch line.origin {
            case .estimate:
                if estimatedFoods == nil {
                    estimatedFoods = try foods.customFoods().filter { $0.notes == Self.estimatedFoodNotes }
                }
                let food = try Self.estimatedFood(for: line, among: &estimatedFoods!, in: foods)
                items.append(.init(food: food, quantity: .base(grams)))
            case let .local(.food(food)):
                items.append(.init(food: food, quantity: .base(grams)))
            case let .local(.bundled(bundled)):
                try items.append(.init(food: foods.localCopy(of: bundled), quantity: .base(grams)))
            }
        }
        if !items.isEmpty {
            try diary.logAll(items, slotID: slotID, day: day)
        }
    }

    /// The food for an estimated line: an earlier estimated food with the same name and values, else a new one.
    private static func estimatedFood(for line: Line, among existing: inout [Food], in foods: FoodRepository) throws -> Food {
        let trimmed = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Estimated food" : trimmed
        let isLiquid = line.unit == .milliliters
        if let match = existing.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.isLiquid == isLiquid && sameValues($0.per100, line.per100)
        }) {
            return match
        }
        let food = try foods.save(FoodDetail(food: Food(
            name: name, per100: line.per100, isLiquid: isLiquid, notes: estimatedFoodNotes,
        ))).food
        existing.append(food)
        return food
    }

    /// Equal to a tenth of a unit: estimates round-trip through text and scaling.
    private static func sameValues(_ a: Nutrients, _ b: Nutrients) -> Bool {
        let close = { (x: Double, y: Double) in abs(x - y) < 0.05 }
        return close(a.kcal, b.kcal) && close(a.proteinG, b.proteinG) && close(a.carbsG, b.carbsG) && close(a.fatG, b.fatG)
    }

    private typealias Result = (lines: [Line], notice: String?)

    /// The model does the estimate when it is available and can read what was given: any text, or a photo when it
    /// has vision. A photo alone on a text-only model goes to the matcher.
    static func usesModel(_ estimator: any MealEstimating, photo: Bool, text: String) -> Bool {
        guard estimator.isAvailable else { return false }
        return estimator.supportsPhotos || !photo || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func estimated(_ environment: AppEnvironment) async throws -> Result {
        let foods = try await environment.mealEstimator.estimate(.init(text: text, jpeg: jpeg))
        let lines = foods.map { Line(name: $0.name, grams: $0.grams, per100: $0.per100, origin: .estimate) }
        return (lines, "An estimate made on this iPhone by Apple Intelligence. Check the foods and amounts before logging.")
    }

    private func matched(_ environment: AppEnvironment) async throws -> Result {
        guard let search = environment.search, let foods = environment.foods else { throw MealEstimateError.noFood }
        let matcher = OnDeviceMealMatcher(search: search, foods: foods)
        let described = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let match: OnDeviceMealMatcher.Match
        if described {
            match = try matcher.match(text: text)
        } else if let jpeg {
            match = try await matcher.match(labels: environment.imageLabeler.labels(jpeg: jpeg))
        } else {
            match = .init()
        }
        guard !match.lines.isEmpty else { throw OnDeviceError.nothingMatched }
        var notice = described
            ? "Matched to foods on this iPhone. Check each food and its amount."
            : "A guess at what the photo shows, matched to foods on this iPhone. Amounts are not estimated: set them yourself."
        if !match.unmatched.isEmpty {
            notice += " Not found: \(match.unmatched.joined(separator: ", "))."
        }
        return (match.lines, notice)
    }

    private enum OnDeviceError: Error {
        case nothingMatched
    }

    static func message(for error: any Error) -> String {
        switch error {
        case OnDeviceError.nothingMatched:
            "Nothing matched a food on this iPhone. Search for it instead."
        case MealEstimateError.unavailable:
            "Apple Intelligence isn't available right now. Try again in a moment."
        case MealEstimateError.noFood:
            "Couldn't find any food in that. Try another photo, or describe the meal."
        case MealEstimateError.refused:
            "The estimate was declined. Describe the meal in words instead."
        case is MealEstimateError:
            "The estimate failed. Try again."
        default:
            error.localizedDescription
        }
    }
}
