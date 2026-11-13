import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

@MainActor
struct IntentActionsTests {
    let clock = ManualClock() // noon → lunch
    let source = FakeHealthDataSource()
    let writer: FakeHealthWriter
    let env: AppEnvironment
    let actions: IntentActions

    init() {
        writer = FakeHealthWriter(mirror: source)
        env = AppEnvironment.preview(clock: clock.appClock, health: source, healthWriter: writer)
        actions = IntentActions(environment: env, locale: Locale(identifier: "en_US"))
    }

    @Test func `log favorite: usual amount, explicit amount, through the same repositories and Health`() async throws {
        let foods = try #require(env.foods), diary = try #require(env.diary)
        let coffee = try foods.save(FoodDetail(
            food: Food(name: "Coffee with milk", per100: Nutrients(kcal: 40, proteinG: 2, carbsG: 3, fatG: 2), isLiquid: true),
            servings: [Serving(label: "cup", grams: 200)],
        ))
        try foods.setFavorite(id: coffee.food.id, true)
        #expect(try actions.favorites().map(\.name) == ["Coffee with milk"])
        #expect(try actions.currentSlot().id == "lunch")

        // Never logged: 100 ml by default.
        let first = try await actions.logFood(id: coffee.food.id, amount: nil)
        #expect(first.contains("Coffee with milk") && first.contains("Lunch"))
        // An explicit amount, then "the usual" repeats it.
        _ = try await actions.logFood(id: coffee.food.id, amount: 250)
        _ = try await actions.logFood(id: coffee.food.id, amount: nil)
        let entries = try diary.diary(for: env.today).sections.first { $0.slot.id == "lunch" }?.entries ?? []
        #expect(entries.map(\.grams) == [100, 250, 250])
        #expect(try foods.food(id: coffee.food.id)?.useCount == 3)
        // Written to Apple Health before the intent returns.
        #expect(writer.snapshot.samples(for: entries[1].id).contains { $0.type == .dietaryEnergyConsumed && $0.value == 100 })
        #expect(try HealthKitLinkRepository(#require(env.db), clock: clock.appClock).pending().isEmpty)

        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.logFood(id: coffee.food.id, amount: 0) }
        try foods.softDelete(id: coffee.food.id)
        await #expect(throws: IntentActions.Failure.foodNotFound) { try await actions.logFood(id: coffee.food.id, amount: nil) }
        #expect(try actions.foods(ids: [coffee.food.id, "nope"]).isEmpty)
    }

    @Test func `quick-add and remaining calories`() async throws {
        #expect(try actions.remainingSentence().contains("Set a calorie target"))
        try #require(env.profiles).setTarget(Target(
            effectiveFrom: env.today, kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 67), origin: .manual,
        ))
        #expect(try actions.remaining().remainingKcal == 2000)
        let message = try await actions.quickAdd(kcal: 640, name: "Lunch out")
        #expect(message == "Added 640 kcal to Lunch. You have \(EnergyUnit.kcal.format(1360)) left today.")
        let entry = try #require(try env.diary?.diary(for: env.today).sections.flatMap(\.entries).first)
        #expect(entry.isQuickAdd && entry.displayName == "Lunch out" && entry.mealSlotID == "lunch")
        #expect(!writer.snapshot.samples(for: entry.id).isEmpty)

        _ = try await actions.quickAdd(kcal: 1500, name: nil)
        #expect(try actions.remainingSentence() == "You are 140 kcal over your target today.")
        #expect(try actions.remaining().remainingKcal == -140)
        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.quickAdd(kcal: -5, name: nil) }
    }

    @Test func `log water counts other apps' water and reaches Health`() async throws {
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: env.today, waterMl: 400)])
        let message = try await actions.logWater(ml: 330)
        #expect(message == "Logged 330 ml of water. 730 of 2,500 ml today.")
        let entry = try #require(try env.water?.entries(for: env.today).first)
        #expect(writer.snapshot.samples(for: entry.id).first?.type == .dietaryWater)
        await #expect(throws: IntentActions.Failure.invalidAmount) { try await actions.logWater(ml: 0) }
    }

    // swiftformat:disable:next swiftTestingTestCaseNames
    @Test func logWaterReportsHydrationTotal() async throws {
        try #require(env.water).add(ml: 500, day: env.today)
        let cola = try #require(env.foods).save(FoodDetail(food: Food(
            name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0), isLiquid: true,
        ))).food
        _ = try #require(env.diary).log(food: cola, quantity: .base(330), slotID: "snacks", day: env.today)
        let message = try await actions.logWater(ml: 250)
        // Still plain water: only the new 250 ml is a water entry; the total counts every drink.
        #expect(message == "Logged 250 ml of water. 1,080 of 2,500 ml today.")
        #expect(try env.water?.entries(for: env.today).count == 2)
    }

    @Test func `the evening is dinner, and a new day is picked up`() async throws {
        clock.advance(hours: 7) // 19:00
        #expect(try actions.currentSlot().id == "dinner")
        clock.advance(hours: 24)
        let yesterday = env.today
        _ = try await actions.quickAdd(kcal: 100, name: nil)
        #expect(env.today == yesterday.next)
        #expect(try env.diary?.diary(for: yesterday.next).entryCount == 1)
    }

    @Test func `intents fail clearly without a database`() async {
        let broken = IntentActions(environment: AppEnvironment(
            database: .failed("x"),
            config: AppConfig(usdaAPIKey: nil),
            bundledIndex: nil,
            openFoodFacts: StubOpenFoodFactsClient(),
            offSearch: StubOpenFoodFactsSearchClient(),
        ))
        await #expect(throws: IntentActions.Failure.databaseUnavailable) { try await broken.logWater(ml: 100) }
        #expect(throws: IntentActions.Failure.databaseUnavailable) { try broken.remaining() }
    }
}
