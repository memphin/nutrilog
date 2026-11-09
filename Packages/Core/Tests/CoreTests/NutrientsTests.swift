import Foundation
import Testing
@testable import Core

struct NutrientsTests {
    let oats = Nutrients(kcal: 379, proteinG: 13.2, carbsG: 67.7, fatG: 6.5, fiberG: 10.1, sugarG: 1, satFatG: nil, sodiumMg: 6)

    @Test func `scales from per 100 to grams`() {
        let n = oats.scaled(toGrams: 50)
        #expect(n.kcal == 189.5)
        #expect(n.proteinG == 6.6)
        #expect(n.fiberG == 5.05)
        #expect(n.satFatG == nil)
        #expect(n.sodiumMg == 3)
    }

    @Test func `scaling by zero gives zero but keeps optional presence`() {
        let n = oats.scaled(toGrams: 0)
        #expect(n.kcal == 0)
        #expect(n.fiberG == 0)
        #expect(n.satFatG == nil)
    }

    @Test func `scales and rounds when every optional is present`() {
        let full = Nutrients(kcal: 200, proteinG: 10, carbsG: 20, fatG: 8, fiberG: 3, sugarG: 5.55, satFatG: 2.22, sodiumMg: 101)
        #expect(full.scaled(by: 2) == Nutrients(
            kcal: 400,
            proteinG: 20,
            carbsG: 40,
            fatG: 16,
            fiberG: 6,
            sugarG: 11.1,
            satFatG: 4.44,
            sodiumMg: 202,
        ))
        let rounded = full.displayRounded
        #expect(rounded.sugarG == 5.6)
        #expect(rounded.satFatG == 2.2)
        #expect(rounded.sodiumMg == 101)
    }

    @Test func `addition treats nil as missing not zero`() {
        let a = Nutrients(kcal: 100, proteinG: 1, carbsG: 2, fatG: 3, fiberG: nil, sugarG: 4, satFatG: nil, sodiumMg: 10)
        let b = Nutrients(kcal: 50, proteinG: 1, carbsG: 1, fatG: 1, fiberG: 2, sugarG: nil, satFatG: nil, sodiumMg: 5)
        let sum = a + b
        #expect(sum.kcal == 150)
        #expect(sum.proteinG == 2)
        #expect(sum.carbsG == 3)
        #expect(sum.fatG == 4)
        #expect(sum.fiberG == 2) // nil + 2
        #expect(sum.sugarG == 4) // 4 + nil
        #expect(sum.satFatG == nil) // nil + nil
        #expect(sum.sodiumMg == 15)
    }

    @Test func `plus equals and sum`() {
        var total = Nutrients.zero
        total += oats
        #expect(total == Nutrients.zero + oats)
        #expect(Nutrients.sum([oats, oats]).kcal == 758)
        #expect(Nutrients.sum([Nutrients]()) == .zero)
    }

    @Test func `stored kcal is never recomputed`() {
        // Label says 500 kcal although macros imply 4*10 + 4*10 + 9*10 = 170.
        let odd = Nutrients(kcal: 500, proteinG: 10, carbsG: 10, fatG: 10)
        #expect(odd.scaled(toGrams: 100).kcal == 500)
        #expect(odd.kcalFromMacros == 170)
        #expect(odd.hasImplausibleEnergy())
    }

    @Test func `plausibility within tolerance`() {
        #expect(!oats.hasImplausibleEnergy()) // 4*13.2+4*67.7+9*6.5 = 382.1 vs 379
        let water = Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
        #expect(water.energyMismatch == nil)
        #expect(!water.hasImplausibleEnergy())
        let slightlyOff = Nutrients(kcal: 100, proteinG: 0, carbsG: 22, fatG: 0) // 88 → 12 %
        #expect(!slightlyOff.hasImplausibleEnergy())
        #expect(slightlyOff.hasImplausibleEnergy(tolerance: 0.1))
    }

    @Test func `per serving to per 100`() {
        let perSlice = Nutrients(kcal: 60, proteinG: 2, carbsG: 11, fatG: 1, fiberG: 1.5)
        let per100 = Nutrients.per100(fromServing: perSlice, servingGrams: 25)
        #expect(per100.kcal == 240)
        #expect(per100.carbsG == 44)
        #expect(per100.fiberG == 6)
    }

    @Test func `salt sodium conversion`() {
        #expect(Salt.sodiumMg(fromSaltG: 1.25) == 500)
        #expect(Salt.saltG(fromSodiumMg: 400) == 1)
    }

    @Test func `macro energy shares`() {
        let n = Nutrients(kcal: 0, proteinG: 25, carbsG: 25, fatG: 0)
        let shares = n.macroEnergyShares
        #expect(shares.protein == 0.5)
        #expect(shares.carbs == 0.5)
        #expect(shares.fat == 0)
        let none = Nutrients.zero.macroEnergyShares
        #expect(none.protein == 0 && none.carbs == 0 && none.fat == 0)
    }

    @Test func `codable round trip`() throws {
        let data = try JSONEncoder().encode(oats)
        #expect(try JSONDecoder().decode(Nutrients.self, from: data) == oats)
    }

    @Test func `display rounding`() {
        let n = Nutrients(kcal: 189.5, proteinG: 6.64, carbsG: 33.86, fatG: 0.04, fiberG: 5.05, sugarG: nil, satFatG: 12.4, sodiumMg: 3.6)
        let r = n.displayRounded
        #expect(r.kcal == 190)
        #expect(r.proteinG == 6.6)
        #expect(r.carbsG == 34)
        #expect(r.fatG == 0)
        #expect(r.fiberG == 5.1)
        #expect(r.sugarG == nil)
        #expect(r.satFatG == 12)
        #expect(r.sodiumMg == 4)
        #expect(DisplayRounding.gramsText(4.0) == "4")
        #expect(DisplayRounding.gramsText(4.46) == "4.5")
        #expect(DisplayRounding.kcal(-0.4) == 0)
        #expect(DisplayRounding.milligrams(2.5) == 3)
    }
}

struct QuantityTests {
    let slice = ServingSize(label: "slice", amount: 25)

    @Test func `base amount`() {
        #expect(Quantity.base(150).baseAmount == 150)
        #expect(Quantity.servings(count: 2, serving: slice).baseAmount == 50)
        #expect(Quantity.servings(count: 1.5, serving: slice).baseAmount == 37.5)
    }

    @Test func `liquids use millilitres`() {
        #expect(BaseUnit(isLiquid: true) == .milliliters)
        #expect(BaseUnit(isLiquid: false) == .grams)
        #expect(BaseUnit.milliliters.symbol == "ml")
        let milk = Nutrients(kcal: 64, proteinG: 3.3, carbsG: 4.8, fatG: 3.6)
        #expect(Quantity.servings(count: 1, serving: ServingSize(label: "glass", amount: 250)).nutrients(per100: milk).kcal == 160)
    }

    @Test func `serving labels`() {
        #expect(Quantity.base(100).servingLabel == nil)
        #expect(Quantity.servings(count: 2, serving: slice).servingLabel == "2 × slice")
        #expect(Quantity.servings(count: 0.5, serving: slice).servingLabel == "0.5 × slice")
    }

    @Test func `compact numbers`() {
        #expect(NumberFormatting.compact(1) == "1")
        #expect(NumberFormatting.compact(1.5) == "1.5")
        #expect(NumberFormatting.compact(0.25) == "0.25")
        #expect(NumberFormatting.compact(2.999) == "3")
        #expect(NumberFormatting.compact(0.1 + 0.2) == "0.3")
    }
}
