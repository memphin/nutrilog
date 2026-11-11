import Foundation
import Testing
@testable import Core

struct EnergyTests {
    @Test func `mifflin st jeor published examples`() {
        // Male, 80 kg, 180 cm, 30 y: 800 + 1125 − 150 + 5 = 1780
        #expect(Energy.mifflinStJeor(weightKg: 80, heightCm: 180, ageYears: 30, sex: .male) == 1780)
        // Female, 60 kg, 165 cm, 25 y: 600 + 1031.25 − 125 − 161 = 1345.25
        #expect(Energy.mifflinStJeor(weightKg: 60, heightCm: 165, ageYears: 25, sex: .female) == 1345.25)
        // Other uses the midpoint constant −78.
        #expect(Energy.mifflinStJeor(weightKg: 70, heightCm: 170, ageYears: 40, sex: .other) == 1484.5) // 700 + 1062.5 − 200 − 78
    }

    @Test func `baseline TDEE uses activity factor`() {
        #expect(Energy.baselineTDEE(bmr: 1780, activity: .sedentary) == 1780 * 1.2)
        #expect(Energy.baselineTDEE(bmr: 1780, activity: .moderate) == 1780 * 1.55)
        #expect(ActivityLevel.allCases.map(\.factor) == [1.2, 1.375, 1.55, 1.725, 1.9])
        #expect(ActivityLevel(rawValue: "very_active") == .veryActive)
        #expect(ActivityLevel.allCases.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty })
    }

    @Test func `measured TDEE averages Health energy and drops partial days`() throws {
        // Too few days.
        #expect(Energy.measuredTDEE(dailyTotalKcal: Array(repeating: 2500, count: 6)) == nil)
        #expect(Energy.measuredTDEE(dailyTotalKcal: [nil, nil]) == nil)
        // Missing days are skipped; a barely-worn day (900 vs median ~2500) is left out.
        let days: [Double?] = [2400, 2600, nil, 2500, 2450, 2550, 900, 2500, 2500]
        let measured = try #require(Energy.measuredTDEE(dailyTotalKcal: days))
        #expect(measured.days == 7)
        #expect(measured.kcal == 2500)
    }

    @Test func `goal deltas and targets`() {
        #expect(Energy.dailyDelta(goal: .lose, rateKgPerWeek: 0.5) == -550)
        #expect(Energy.dailyDelta(goal: .gain, rateKgPerWeek: 0.25) == 275)
        #expect(Energy.dailyDelta(goal: .maintain, rateKgPerWeek: 0.5) == 0)
        #expect(Energy.dailyDelta(goal: .lose, rateKgPerWeek: -0.5) == -550) // sign comes from mode only
        #expect(Energy.calorieTarget(tdee: 2759, goal: .lose, rateKgPerWeek: 0.5) == 2210) // 2209 → 2210
        #expect(Energy.calorieTarget(tdee: 2500, goal: .maintain, rateKgPerWeek: 0) == 2500)
    }

    @Test func `age on day`() throws {
        let birth = try #require(LocalDay("1990-11-10"))
        #expect(try Energy.age(birthDate: birth, on: #require(LocalDay("2026-11-09"))) == 35)
        #expect(try Energy.age(birthDate: birth, on: #require(LocalDay("2026-11-10"))) == 36)
    }
}

struct MacroTests {
    @Test func `split validation`() {
        #expect(MacroSplit.balanced.isValid)
        #expect(MacroSplit(proteinPct: 33.3, carbsPct: 33.3, fatPct: 33.3).isValid) // 99.9 within ±0.5
        #expect(!MacroSplit(proteinPct: 40, carbsPct: 40, fatPct: 30).isValid)
        #expect(!MacroSplit(proteinPct: -10, carbsPct: 80, fatPct: 30).isValid)
    }

    @Test func `grams from split`() {
        let g = MacroSplit.balanced.grams(forKcal: 2000)
        #expect(g == MacroTargets(proteinG: 150, carbsG: 200, fatG: 67))
        #expect(abs(g.kcal - 2003) < 0.01)
    }

    @Test func `split from grams round trips`() {
        let split = MacroSplit(from: MacroTargets(proteinG: 150, carbsG: 200, fatG: 200.0 / 3))
        #expect(abs(split.proteinPct - 30) < 0.01)
        #expect(abs(split.carbsPct - 40) < 0.01)
        #expect(abs(split.fatPct - 30) < 0.01)
        #expect(MacroSplit(from: MacroTargets(proteinG: 0, carbsG: 0, fatG: 0)) == .balanced)
    }

    @Test func `goal mode raw values`() {
        #expect(GoalMode(rawValue: "lose") == .lose)
        #expect(Sex(rawValue: "other") == .other)
    }
}

struct SlotSuggestionTests {
    let slots: [MealSlotSuggestion.Slot] = [
        .init(id: "breakfast", startHour: 5, sortOrder: 0),
        .init(id: "lunch", startHour: 11, sortOrder: 1),
        .init(id: "dinner", startHour: 17, sortOrder: 2),
        .init(id: "snacks", startHour: nil, sortOrder: 3),
    ]

    @Test(arguments: [(7, "breakfast"), (5, "breakfast"), (11, "lunch"), (16, "lunch"), (20, "dinner"), (2, "dinner")])
    func `picks slot by hour`(hour: Int, expected: String) {
        #expect(MealSlotSuggestion.slot(forHour: hour, among: slots) == expected)
    }

    @Test func `untimed slots fall back to sort order`() {
        let untimed: [MealSlotSuggestion.Slot] = [
            .init(id: "b", startHour: nil, sortOrder: 1),
            .init(id: "a", startHour: nil, sortOrder: 0),
        ]
        #expect(MealSlotSuggestion.slot(forHour: 9, among: untimed) == "a")
        #expect(MealSlotSuggestion.slot(forHour: 9, among: []) == nil)
    }

    @Test func `recents prefer slot frequency then recency`() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 86400
        let ranked = RecentsRanking.rank([
            .init(foodID: "pizza", countInSlot: 0, countTotal: 6, lastUsed: now - day),
            .init(foodID: "oats", countInSlot: 5, countTotal: 5, lastUsed: now - 3 * day),
            .init(foodID: "coffee", countInSlot: 1, countTotal: 1, lastUsed: now - 60 * day),
            .init(foodID: "tie-newer", countInSlot: 1, countTotal: 1, lastUsed: now - 59 * day),
        ], now: now)
        #expect(ranked == ["oats", "pizza", "tie-newer", "coffee"])
    }
}
