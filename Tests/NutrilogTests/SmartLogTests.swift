import Core
import Foundation
import Persistence
import Testing
@testable import Nutrilog

private struct StubEstimator: MealEstimating {
    var isAvailable = true
    var supportsPhotos = true
    var result: Result<[EstimatedFood], MealEstimateError>

    func estimate(_: MealEstimateRequest) async throws -> [EstimatedFood] {
        try result.get()
    }
}

private struct StubLabeler: FoodImageLabeling {
    var found: [String]

    func labels(jpeg _: Data) async throws -> [String] {
        found
    }
}

@MainActor
struct SmartLogTests {
    private let day = LocalDay("2026-11-10")!

    private func environment(
        estimator: any MealEstimating = NoMealEstimator(), labels: [String] = [],
    ) throws -> (AppEnvironment, slotID: String) {
        let env = try AppEnvironment(
            database: .ready(AppDatabase.inMemory()),
            config: AppConfig(usdaAPIKey: nil),
            bundledIndex: nil,
            mealEstimator: estimator,
            imageLabeler: StubLabeler(found: labels),
        )
        let foods = try #require(env.foods)
        try foods.save(FoodDetail(
            food: Food(name: "Egg", per100: Nutrients(kcal: 150, proteinG: 13, carbsG: 1, fatG: 10)),
            servings: [Serving(label: "egg", grams: 60)],
        ))
        // Logged before, so search ranks it above "Egg" for the prefix "egg".
        let eggplant = try foods.save(FoodDetail(food: Food(name: "Eggplant, raw", per100: Nutrients(kcal: 25, proteinG: 1, carbsG: 6, fatG: 0.2))))
        try env.diary?.log(food: eggplant.food, quantity: .base(50), slotID: #require(env.diary?.mealSlots().last).id, day: LocalDay("2026-11-01")!)
        try foods.save(FoodDetail(food: Food(name: "Banana", per100: Nutrients(kcal: 90, proteinG: 1, carbsG: 23, fatG: 0.3))))
        let slot = try #require(env.diary?.mealSlots().first)
        return (env, slot.id)
    }

    @Test func `model estimate is reviewed, edited and logged as quick-add entries`() async throws {
        let rice = EstimatedFood(name: "Rice", grams: 200, per100: Nutrients(kcal: 130, proteinG: 2.5, carbsG: 28, fatG: 0.3))
        let (env, slotID) = try environment(estimator: StubEstimator(result: .success([rice])))
        let model = SmartLogModel()
        #expect(!model.canEstimate)
        model.text = "a bowl of rice"
        await model.estimate(in: env)

        #expect(model.phase == .review)
        #expect(model.totals.kcal == 260)
        model.lines[0].amountText = "100"
        #expect(model.totals.kcal == 130)
        model.lines[0].amountText = ""
        #expect(!model.canLog)
        model.lines[0].amountText = "100"

        try model.log(slotID: slotID, day: day, in: env)
        let entries = try #require(env.diary).diary(for: day).sections.flatMap(\.entries)
        #expect(entries.map(\.displayName) == ["Rice (100 g)"])
        #expect(entries[0].isQuickAdd)
        #expect(entries[0].kcal == 130)
    }

    @Test func `without the model the description is matched to foods on the phone and logged as those foods`() async throws {
        let (env, slotID) = try environment()
        #expect(!env.mealEstimator.isAvailable)
        let model = SmartLogModel()
        model.text = "2 eggs, 150 g banana and caviar"
        await model.estimate(in: env)

        #expect(model.phase == .review)
        #expect(model.lines.map(\.name) == ["Egg", "Banana"])
        #expect(model.lines.map(\.grams) == [120, 150]) // 2 × the 60 g serving; the stated 150 g
        #expect(model.notice?.contains("Not found: caviar") == true)

        try model.log(slotID: slotID, day: day, in: env)
        let entries = try #require(env.diary).diary(for: day).sections.flatMap(\.entries)
        #expect(entries.map(\.displayName) == ["Egg", "Banana"])
        #expect(entries.allSatisfy { !$0.isQuickAdd && $0.foodID != nil })
        #expect(entries[0].kcal == 180)
    }

    @Test func `without the model a photo is matched by its labels, skipping vague ones`() async throws {
        let (env, _) = try environment(labels: ["food", "fruit", "banana", "sofa"])
        let model = SmartLogModel()
        model.jpeg = Data([1])
        await model.estimate(in: env)
        #expect(model.lines.map(\.name) == ["Banana"])
        #expect(model.lines[0].grams == 100)
    }

    @Test func `a failed estimate returns to the input with a message`() async throws {
        let (env, _) = try environment(estimator: StubEstimator(result: .failure(.refused)))
        let model = SmartLogModel()
        model.text = "soup"
        await model.estimate(in: env)
        #expect(model.phase == .input)
        #expect(model.errorMessage?.contains("declined") == true)
        #expect(model.text == "soup")

        let (keyless, _) = try environment()
        model.errorMessage = nil
        model.text = "caviar"
        await model.estimate(in: keyless)
        #expect(model.errorMessage?.contains("Nothing matched") == true)
    }

    @Test func `a photo alone goes to the model only when it has vision`() {
        let textOnly = StubEstimator(supportsPhotos: false, result: .success([]))
        #expect(SmartLogModel.usesModel(textOnly, photo: false, text: "soup"))
        #expect(SmartLogModel.usesModel(textOnly, photo: true, text: "soup"))
        #expect(!SmartLogModel.usesModel(textOnly, photo: true, text: " "))
        #expect(SmartLogModel.usesModel(StubEstimator(result: .success([])), photo: true, text: ""))
        #expect(!SmartLogModel.usesModel(NoMealEstimator(), photo: false, text: "soup"))
    }
}
