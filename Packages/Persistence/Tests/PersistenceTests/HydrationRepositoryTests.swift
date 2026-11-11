import Core
import Foundation
import Testing
@testable import Persistence

struct HydrationRepositoryTests {
    let d = day("2026-11-09")

    private func cola(_ f: Fixture) throws -> Food {
        let food = Food(name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0), isLiquid: true)
        return try f.foods.save(FoodDetail(food: food)).food
    }

    @Test func `merges three sources`() throws {
        let f = try Fixture()
        let hydration = HydrationRepository(f.db)
        let start = f.clock.now
        let diary = try f.diary.log(food: cola(f), quantity: .base(330), slotID: "snacks", day: d) // at start
        let water = try f.water.add(ml: 250, day: d, loggedAt: start.addingTimeInterval(3600))
        let espresso = try f.caffeine.add(mg: 64, day: d, loggedAt: start.addingTimeInterval(1800), drinkID: "espresso")
        let custom = try f.caffeine.add(mg: 80, day: d.next, loggedAt: start, name: "Cold brew", ml: 200)

        let intakes = try hydration.intakes(in: d ... d.next)
        #expect(intakes[d] == [
            FluidIntake(id: diary.id, ml: 330, at: start, kind: .other, source: .diary, name: "Cola"),
            // No stored name: the preset's.
            FluidIntake(id: espresso.id, ml: 30, at: start.addingTimeInterval(1800), kind: .other, source: .caffeine, name: "Espresso"),
            FluidIntake(id: water.id, ml: 250, at: start.addingTimeInterval(3600), kind: .water, source: .water, name: "Water"),
        ])
        #expect(intakes[d.next] == [
            FluidIntake(id: custom.id, ml: 200, at: start, kind: .other, source: .caffeine, name: "Cold brew"),
        ])
        #expect(intakes.count == 2)
        #expect(try hydration.intakes(in: d.next ... d.next) == [d.next: #require(intakes[d.next])])
    }

    @Test func `same time intakes are ordered by id`() throws {
        let f = try Fixture()
        let at = f.clock.now
        let a = try f.water.add(ml: 100, day: d, loggedAt: at)
        let b = try f.water.add(ml: 200, day: d, loggedAt: at)
        let ids = try HydrationRepository(f.db).intakes(in: d ... d)[d]?.map(\.id)
        #expect(ids == [a.id, b.id].sorted())
    }

    @Test func `excludes deleted and non fluid`() throws {
        let f = try Fixture()
        let hydration = HydrationRepository(f.db)
        let drink = try cola(f)
        let deletedWater = try f.water.add(ml: 250, day: d)
        try f.water.softDelete(ids: [deletedWater.id])
        let deletedCola = try f.diary.log(food: drink, quantity: .base(330), slotID: "snacks", day: d)
        try f.diary.softDelete(entryIDs: [deletedCola.id])
        try f.diary.log(food: f.makeFood("Bread"), quantity: .base(50), slotID: "lunch", day: d)
        try f.diary.logQuickAdd(name: "Soup", nutrients: Nutrients(kcal: 100, proteinG: 1, carbsG: 1, fatG: 1), slotID: "lunch", day: d)
        try f.caffeine.add(mg: 80, day: d) // custom without a volume
        let deletedEspresso = try f.caffeine.add(mg: 64, day: d, drinkID: "espresso")
        try f.caffeine.softDelete(ids: [deletedEspresso.id])
        try f.water.add(ml: 300, day: d.next) // outside the range
        #expect(try hydration.intakes(in: d ... d).isEmpty)

        let kept = try f.water.add(ml: 200, day: d)
        #expect(try hydration.intakes(in: d ... d)[d]?.map(\.id) == [kept.id])
    }

    @Test func `observation emits on diary change`() async throws {
        let f = try Fixture()
        let drink = try cola(f)
        var iterator = HydrationRepository(f.db).observeIntakes(in: d ... d).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == [:])
        let entry = try f.diary.log(food: drink, quantity: .base(330), slotID: "snacks", day: d)
        let second = try await iterator.next()
        #expect(second?[d]?.map(\.id) == [entry.id])
        try f.diary.updateQuantity(entryID: entry.id, quantity: .base(500))
        let third = try await iterator.next()
        #expect(third?[d]?.map(\.ml) == [500])
        try f.diary.softDelete(entryIDs: [entry.id])
        let fourth = try await iterator.next()
        #expect(fourth == [:])
    }
}
