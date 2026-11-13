import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// The Hydration detail (spec §3): the status line, adding water at an earlier time, deleting today's drinks with
/// undo (diary drinks are changed in the diary), and the last 14 days against each day's own goal.
@MainActor
struct HydrationDetailTests {
    @Test func `status lines`() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(HydrationStatusText.line(.goalReached, now: now) == "Goal reached")
        #expect(HydrationStatusText.line(.onPace, now: now) == "On pace")
        #expect(HydrationStatusText.line(.behind(byMl: 500), now: now) == "500 ml behind pace")
        let since = now.addingTimeInterval(-(3 * 3600 + 20 * 60))
        #expect(HydrationStatusText.line(.inGap(since: since), now: now) == "No drink for 3 h 20 min")
    }

    @Test func `the chart spans wake-up to bedtime, drinks at odd times drawn at its edges`() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        func at(_ hour: Double) -> Date {
            start.addingTimeInterval(hour * 3600)
        }
        func water(_ ml: Double, _ hour: Double) -> FluidIntake {
            FluidIntake(id: "\(hour)", ml: ml, at: at(hour), kind: .water, source: .water, name: "Water")
        }
        let day = HydrationDay(
            intakes: [water(250, 2), water(500, 9), water(100, 23.75)], otherAppsMl: 0, goalMl: 2500,
            wake: at(7), bedtime: at(23), gapThreshold: 3 * 3600, behindMarginMl: 500, now: at(23.9),
        )
        let window = HydrationChart.window(day)
        #expect(window == at(7) ... at(23))
        // The 02:00 glass counts from wake-up; the late one at bedtime.
        #expect(HydrationChart.points(day, window: window).map { [$0.at, $0.totalMl] as [AnyHashable] }
            == [[at(7), 250.0], [at(9), 750.0], [at(23), 850.0]])
        #expect(HydrationChart.totalLine(day, window: window).map { [$0.at, $0.totalMl] as [AnyHashable] }
            == [[at(7), 250.0], [at(9), 750.0], [at(23), 850.0]])
    }

    @Test func `delete water intake offers undo`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        model.addWater(ml: 500)
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.count == 1 })
        let intake = try #require(model.data.hydrationIntakes[model.data.today]?.first)
        #expect(intake.isDeletable)
        model.deleteIntake(intake)
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today] == nil })
        #expect(model.undo.current?.message == "Removed 500 ml water")
        model.undo.performUndo()
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.map(\.id) == [intake.id] })
    }

    @Test func `delete caffeine intake offers undo`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let caffeine = try #require(env.caffeine)
        try caffeine.add(mg: 64, day: env.today, drinkID: "espresso")
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.count == 1 })
        let intake = try #require(model.data.hydrationIntakes[model.data.today]?.first)
        #expect(intake.source == .caffeine)
        #expect(intake.isDeletable)
        model.deleteIntake(intake)
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today] == nil })
        #expect(model.undo.current?.message == "Removed Espresso")
        model.undo.performUndo()
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.map(\.id) == [intake.id] })
    }

    @Test func `diary intake not deletable`() async throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let diary = try #require(env.diary)
        let food = try #require(env.foods).save(FoodDetail(food: Food(
            name: "Cola", per100: Nutrients(kcal: 42, proteinG: 0, carbsG: 10.6, fatG: 0), isLiquid: true,
        ))).food
        let entry = try diary.log(food: food, quantity: .base(330), slotID: "snacks", day: env.today)
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.count == 1 })
        let intake = try #require(model.data.hydrationIntakes[model.data.today]?.first)
        #expect(intake.source == .diary)
        #expect(!intake.isDeletable)
        // The row shows the meal it was logged in.
        let slot = try #require(try diary.mealSlots().first { $0.id == entry.mealSlotID })
        #expect(model.diaryMealNames(for: [intake]) == [intake.id: slot.name])

        model.deleteIntake(intake)
        #expect(model.undo.current == nil)
        #expect(try diary.entry(id: entry.id)?.deletedAt == nil)
    }

    @Test func `add water at earlier time`() async throws {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        let earlier = model.now.addingTimeInterval(-3 * 3600)
        model.addWater(ml: 300, loggedAt: earlier)
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today]?.count == 1 })
        let intake = try #require(model.data.hydrationIntakes[model.data.today]?.first)
        #expect(intake.at == earlier)
        #expect(intake.ml == 300)
        #expect(model.hydrationDay(at: model.now).steps.map(\.at) == [earlier])
        model.undo.performUndo()
        #expect(await waitUntil { model.data.hydrationIntakes[model.data.today] == nil })
    }

    @Test func `history uses per day goal`() throws {
        let env = AppEnvironment.preview(clock: ManualClock().appClock)
        let today = env.today
        // Every drink counts in the history, not only water.
        try #require(env.water).add(ml: 1000, day: today)
        try #require(env.caffeine).add(mg: 80, day: today, name: "Cold brew", ml: 200)
        try #require(env.water).add(ml: 2100, day: today.adding(days: -2))
        let model = DashboardModel(environment: env)
        let rows = model.history(for: .water)
        #expect(rows.count == TileHistory.days)
        #expect(rows[0].value == Format.ml(1200))
        #expect(rows[0].amountMl == 1200)
        #expect(rows[1].value == nil)
        #expect(rows[2].amountMl == 2100)

        // Each day against its own goal: 70 kg (2 100 ml) two days ago, 80 kg (2 400 ml) today.
        var data = DashboardData(today: today)
        data.weightTrends = [today.adding(days: -2): 70, today.adding(days: -1): 70, today: 80]
        let pure = TileHistory.rows(
            for: .water, data: data, loggedFluidByDay: [today: 1200, today.adding(days: -2): 2100],
        )
        #expect(pure[0].goalMl == 2400)
        #expect(pure[0].detail == "of \(Format.ml(2400))")
        #expect(pure[2].goalMl == 2100)
        #expect(pure[2].detail == "of \(Format.ml(2100))")
        #expect(pure[1].value == nil)
        #expect(pure[1].detail == nil)
    }
}
