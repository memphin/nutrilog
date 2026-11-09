import Core
import Foundation
import Persistence
import Testing
@testable import Nutrilog

@MainActor
struct FoodEditorModelTests {
    @Test func `per 100 from label with salt conversion`() throws {
        let model = FoodEditorModel(energyUnit: .kcal, initialName: "Ajvar")
        model.energy = "80"
        model.protein = "1,5" // comma decimal accepted
        model.carbs = "8"
        model.fat = "4.5"
        model.sodiumOrSalt = "1.25"
        model.entersSalt = true
        let n = try #require(model.per100)
        #expect(n.kcal == 80)
        #expect(n.proteinG == 1.5)
        #expect(n.sodiumMg == 500)
        #expect(n.fiberG == nil)
        #expect(model.canSave)
        #expect(model.warnings.isEmpty)
    }

    @Test func `per serving input is converted to per 100`() throws {
        let model = FoodEditorModel(energyUnit: .kcal, initialName: "Biscuit")
        model.basis = .perServing
        model.basisServingAmount = "25"
        model.energy = "120"
        model.protein = "2"
        model.carbs = "15"
        model.fat = "6"
        let n = try #require(model.per100)
        #expect(n.kcal == 480)
        #expect(n.carbsG == 60)
        model.basisServingAmount = ""
        #expect(model.per100 == nil)
        #expect(model.validationErrors.contains("Enter the serving size."))
    }

    @Test func `kilojoule input is stored as kcal`() throws {
        let model = FoodEditorModel(energyUnit: .kilojoules, initialName: "Juice")
        model.energy = "418.4"
        model.protein = "0"
        model.carbs = "24"
        model.fat = "0"
        #expect(try abs(#require(model.per100).kcal - 100) < 1e-9)
    }

    @Test func `validation and warnings`() {
        let model = FoodEditorModel(energyUnit: .kcal)
        #expect(!model.canSave)
        #expect(model.validationErrors.contains("Enter a name."))
        model.name = "Odd label"
        model.energy = "500"
        model.protein = "10"
        model.carbs = "10"
        model.fat = "10"
        model.sugar = "20"
        #expect(model.canSave) // warnings never block
        #expect(model.warnings.count == 2) // energy mismatch + sugars > carbs
        model.fiber = "abc"
        #expect(!model.canSave)
        model.fiber = ""
        model.servings = [.init(label: "slice", amount: "")]
        #expect(model.validationErrors.contains("Each serving needs a name and an amount."))
        model.servings = []
        model.barcodes = ["123"]
        #expect(model.validationErrors.contains("Barcode 123 is not valid."))
    }

    @Test func `make detail and edit round trip`() throws {
        let model = FoodEditorModel(energyUnit: .kcal, initialName: "  Bread  ", barcode: "3850104003455")
        model.energy = "240"
        model.protein = "8"
        model.carbs = "44"
        model.fat = "3"
        model.addServing()
        model.servings[0].label = "slice"
        model.servings[0].amount = "25"
        model.defaultServingID = model.servings[0].id
        let detail = try #require(model.makeDetail())
        #expect(detail.food.name == "Bread")
        #expect(detail.food.brand == nil)
        #expect(detail.servings.map(\.grams) == [25])
        #expect(detail.food.defaultServingID == detail.servings[0].id)
        #expect(detail.barcodes == ["3850104003455"])

        let reopened = FoodEditorModel(energyUnit: .kcal, editing: detail)
        #expect(reopened.isEditing)
        #expect(reopened.name == "Bread")
        #expect(!reopened.entersSalt) // stored sodium is shown as sodium
        #expect(reopened.servings.first?.label == "slice")
        #expect(reopened.makeDetail()?.food.id == detail.food.id)
    }
}

@MainActor
struct TargetsModelTests {
    func model() throws -> TargetsModel {
        let today = try #require(LocalDay("2026-11-09"))
        let model = TargetsModel(today: today)
        let env = AppEnvironment.preview()
        let profile = try #require(try env.profiles?.profile())
        model.load(profile: profile, target: nil, latestWeightKg: nil)
        return model
    }

    @Test func `formula target from profile`() throws {
        let m = try model()
        #expect(m.formulaKcal == nil)
        #expect(!m.validationErrors.isEmpty)
        m.heightCm = "180"
        m.weightKg = "80"
        m.sex = .male
        m.hasBirthDate = true
        m.birthDate = try #require(LocalDay("1996-11-09")).startDate() // 30 today
        m.activity = .sedentary
        #expect(m.age == 30)
        #expect(m.bmr == 1780)
        #expect(m.tdee == 2136)
        m.goal = .lose
        m.rateKgPerWeek = 0.5
        #expect(m.formulaKcal == 1590) // 2136 − 550 = 1586 → 1590
        let target = try #require(m.makeTarget())
        #expect(target.kcal == 1590)
        #expect(target.origin == .formula)
        #expect(target.macros == MacroSplit.balanced.grams(forKcal: 1590))
        #expect(m.newWeight == 80)
    }

    @Test func `manual override and gram macros`() throws {
        let m = try model()
        m.overrideKcal = true
        m.manualKcal = "2000"
        m.macroInput = .grams
        m.proteinG = "150"
        m.carbsG = "200"
        m.fatG = "70"
        let target = try #require(m.makeTarget())
        #expect(target.origin == .manual)
        #expect(target.proteinG == 150)
        #expect(m.gramsEnergyMismatch == 30) // 600 + 800 + 630 − 2000
    }

    @Test func `percentages must sum to 100`() throws {
        let m = try model()
        m.overrideKcal = true
        m.manualKcal = "2000"
        m.proteinPct = "40"
        #expect(m.percentSum == 110)
        #expect(m.makeTarget() == nil)
        #expect(m.validationErrors.first?.contains("100 %") == true)
        m.carbsPct = "30"
        #expect(m.makeTarget() != nil)
    }

    @Test func `loads existing target and profile`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let env = AppEnvironment.preview()
        var profile = try #require(try env.profiles?.profile())
        profile.heightCm = 170
        profile.goalMode = .gain
        profile.goalRateKgPerWeek = 0.25
        let target = Target(effectiveFrom: today, kcal: 2500, macros: MacroTargets(proteinG: 150, carbsG: 300, fatG: 77), origin: .manual)
        let m = TargetsModel(today: today)
        m.load(profile: profile, target: target, latestWeightKg: 70)
        #expect(m.heightCm == Format.field(170))
        #expect(m.goal == .gain)
        #expect(m.rateKgPerWeek == 0.25)
        #expect(m.overrideKcal)
        #expect(m.newWeight == nil) // unchanged weight is not stored again
        #expect(m.updatedProfile()?.goalRateKgPerWeek == 0.25)
    }
}

@MainActor
struct DiaryModelTests {
    func environment() throws -> (AppEnvironment, Food) {
        let env = AppEnvironment.preview()
        let food = try #require(try env.foods?.save(FoodDetail(food: Food(
            name: "Oats",
            per100: Nutrients(kcal: 380, proteinG: 13, carbsG: 68, fatG: 7),
        ))).food)
        return (env, food)
    }

    @Test func `delete offers undo`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let entry = try #require(try env.diary?.log(food: food, quantity: .base(50), slotID: "breakfast", day: model.day))
        model.delete([entry])
        #expect(try env.diary?.diary(for: model.day).entryCount == 0)
        #expect(model.undo.current?.message == "Deleted Oats")
        model.undo.performUndo()
        #expect(try env.diary?.diary(for: model.day).entryCount == 1)
        #expect(model.undo.current == nil)
    }

    @Test func `copy from yesterday with undo and empty source`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        model.copy(from: model.day.previous, slotID: nil)
        #expect(model.errorMessage?.hasPrefix("Nothing to copy") == true)
        model.errorMessage = nil
        try env.diary?.log(food: food, quantity: .base(40), slotID: "breakfast", day: model.day.previous)
        model.copy(from: model.day.previous, slotID: "breakfast")
        #expect(try env.diary?.diary(for: model.day).entryCount == 1)
        #expect(model.undo.current?.message == "Copied 1 entry")
        model.undo.performUndo()
        #expect(try env.diary?.diary(for: model.day).entryCount == 0)
    }

    @Test func `navigation and notes`() throws {
        let (env, _) = try environment()
        let model = DiaryModel(environment: env)
        #expect(model.isToday)
        model.goToPreviousDay()
        #expect(!model.isToday)
        model.goToNextDay()
        model.goToNextDay()
        model.goToToday()
        #expect(model.isToday)
        model.saveNote(text: "sick", isComplete: false)
        #expect(try env.diary?.note(for: model.day)?.text == "sick")
    }

    @Test func `undo center auto dismisses`() async throws {
        let center = UndoCenter(duration: .milliseconds(50))
        var undone = false
        center.offer("x") { undone = true }
        #expect(center.current != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(center.current == nil)
        center.performUndo() // nothing pending → no-op
        #expect(!undone)
        center.offer("y") {}
        center.dismiss()
        #expect(center.current == nil)
    }
}

struct FormattingTests {
    @Test func `energy units`() {
        #expect(EnergyUnit.kcal.display(100) == 100)
        #expect(abs(EnergyUnit.kilojoules.display(100) - 418.4) < 1e-9)
        #expect(abs(EnergyUnit.kilojoules.fromDisplay(418.4) - 100) < 1e-9)
        #expect(EnergyUnit.kcal.symbol == "kcal")
    }

    @Test func `number parsing`() {
        #expect(Format.number("12,5") == 12.5)
        #expect(Format.number(" 7 ") == 7)
        #expect(Format.number("") == nil)
        #expect(Format.number("abc") == nil)
        #expect(Format.field(nil).isEmpty)
    }

    @Test func `day labels`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        #expect(Format.day(today, today: today) == "Today")
        #expect(Format.day(today.previous, today: today) == "Yesterday")
        #expect(Format.day(today.next, today: today) == "Tomorrow")
        #expect(!Format.day(today.adding(days: -5), today: today).isEmpty)
    }

    @Test func `source badges`() {
        #expect(FoodSource.bundled.badge == .bundled)
        #expect(FoodSource.custom.badge == .custom)
    }
}
