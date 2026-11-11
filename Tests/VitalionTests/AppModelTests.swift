import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

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

    @Test func `editing a non-custom food keeps unedited values and its data quality`() throws {
        let stored = Nutrients(kcal: 61.234, proteinG: 3.2756, carbsG: 4.6312, fatG: 3.2481, sodiumMg: 43.217)
        let food = Food(
            name: "Milk, whole", source: .usda, sourceID: "746782", per100: stored, isLiquid: true,
            dataQuality: .partialMacros,
        )
        let detail = FoodDetail(food: food, servings: [Serving(label: "cup", grams: 244.0123)])
        let model = FoodEditorModel(energyUnit: .kilojoules, editing: detail)
        model.name = "Whole milk"
        let renamed = try #require(model.makeDetail())
        #expect(renamed.food.name == "Whole milk")
        #expect(renamed.food.per100 == stored) // fields show 2 decimals (and kJ); untouched values stay exact
        #expect(renamed.food.dataQuality == .partialMacros)
        #expect(renamed.servings.first?.grams == 244.0123)

        model.protein = "3.4"
        let edited = try #require(model.makeDetail())
        #expect(edited.food.proteinG100 == 3.4)
        #expect(edited.food.kcal100 == stored.kcal)
        #expect(edited.food.fatG100 == stored.fatG)
        #expect(edited.food.sodiumMg100 == stored.sodiumMg)
    }
}

@MainActor
struct FoodsListModelTests {
    @Test func `deleting a food offers undo`() throws {
        let env = AppEnvironment.preview()
        let foods = try #require(env.foods)
        let saved = try foods.save(FoodDetail(
            food: Food(name: "Ajvar", per100: Nutrients(kcal: 80, proteinG: 1.5, carbsG: 8, fatG: 4.5)),
            servings: [Serving(label: "tbsp", grams: 15)],
            barcodes: ["3850104003455"],
        ))
        let model = FoodsListModel(environment: env)
        model.reload()
        #expect(model.foods.map(\.name) == ["Ajvar"])

        model.delete(saved.food)
        #expect(model.foods.isEmpty)
        #expect(model.undo.current?.message == "Deleted Ajvar")

        model.undo.performUndo()
        #expect(model.foods.map(\.name) == ["Ajvar"])
        let restored = try #require(try foods.detail(id: saved.food.id))
        #expect(restored.food.deletedAt == nil)
        #expect(restored.servings.map(\.label) == ["tbsp"])
        #expect(restored.barcodes == ["3850104003455"])
        #expect(model.errorMessage == nil)
    }

    @Test func `food undo is dropped after an import`() throws {
        let env = AppEnvironment.preview()
        let saved = try #require(try env.foods?.save(FoodDetail(food: Food(name: "Ajvar", per100: .zero))))
        let model = FoodsListModel(environment: env)
        model.delete(saved.food)
        try env.dataDidChangeExternally()
        model.undo.performUndo() // still visible if the view hasn't reacted yet: must not resurrect the food
        #expect(try env.foods?.detail(id: saved.food.id)?.food.deletedAt != nil)
        model.delete(saved.food)
        model.dataDidChangeExternally()
        #expect(model.undo.current == nil)
    }
}

@MainActor
struct TargetsModelTests {
    func model(weightKg: Double? = nil) throws -> TargetsModel {
        let today = try #require(LocalDay("2026-11-09"))
        let model = TargetsModel(today: today)
        let env = AppEnvironment.preview()
        let profile = try #require(try env.profiles?.profile())
        model.load(profile: profile, target: nil, latestWeightKg: weightKg, weightDay: weightKg == nil ? nil : today)
        return model
    }

    @Test func `formula target from profile`() throws {
        // The weight is not a field of the form: it is the latest weigh-in (#65).
        let m = try model(weightKg: 80)
        #expect(m.weightKg == 80)
        #expect(m.formulaKcal == nil)
        #expect(!m.validationErrors.isEmpty)
        m.heightCm = "180"
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
    }

    @Test func `measured Health energy replaces the activity factor`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let m = TargetsModel(today: today)
        let profile = try #require(try AppEnvironment.preview().profiles?.profile())
        // No height, age or sex needed: the measured maintenance alone gives a target.
        m.load(profile: profile, target: nil, latestWeightKg: nil, measured: MeasuredTDEE(kcal: 2600, days: 30))
        m.activity = .veryActive // ignored with a measured maintenance
        #expect(m.tdee == 2600)
        #expect(m.formulaKcal == 2600)
        m.goal = .lose
        m.rateKgPerWeek = 0.5
        #expect(m.formulaKcal == 2050) // 2600 − 550
        #expect(m.validationErrors.isEmpty)
        #expect(m.makeTarget()?.kcal == 2050)
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
        #expect(m.weightKg == 70)
        #expect(m.updatedProfile()?.goalRateKgPerWeek == 0.25)
    }

    @Test func `re-saving an unchanged target keeps its gram macros`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let profile = try #require(try AppEnvironment.preview().profiles?.profile())
        let storedMacros = MacroTargets(proteinG: 160, carbsG: 220, fatG: 75) // ≈ 29.2 / 40.1 / 30.8 %
        let stored = Target(effectiveFrom: today.adding(days: -30), kcal: 2200, macros: storedMacros, origin: .manual)
        let m = TargetsModel(today: today)
        m.load(profile: profile, target: stored, latestWeightKg: nil)
        #expect(m.macroInput == .percent)
        #expect(m.fatPct == "31")
        // Recomputing from the rounded 29 / 40 / 31 % would make fat 76 g.
        #expect(m.makeTarget()?.macros == storedMacros)

        m.manualKcal = "2000" // a new calorie target scales the macros by the percentages
        let rescaled = MacroSplit(proteinPct: 29, carbsPct: 40, fatPct: 31).grams(forKcal: 2000)
        #expect(m.makeTarget()?.macros == rescaled)

        m.manualKcal = "2200"
        m.macroInput = .grams
        #expect(m.makeTarget()?.macros == storedMacros)
        m.fatG = "80"
        #expect(m.makeTarget()?.fatG == 80)
    }

    @Test func `without a weigh-in there is no formula target and the form says where to add one`() throws {
        let m = try model()
        m.heightCm = "180"
        m.sex = .male
        m.hasBirthDate = true
        #expect(m.weightKg == nil && m.weightDay == nil)
        #expect(m.formulaKcal == nil)
        #expect(m.validationErrors.first?.contains("Today → Weight") == true)
        m.overrideKcal = true
        m.manualKcal = "2000"
        #expect(m.validationErrors.isEmpty) // a manual target needs no weight
    }

    @Test func `saving writes the target and only what changed`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        try profiles.addWeight(kg: 80.123)

        let empty = TargetsModel(today: today)
        try empty.load(profile: profiles.profile(), target: nil, latestWeightKg: nil)
        #expect(try !empty.save(to: profiles)) // invalid form: nothing written
        #expect(try profiles.target(on: today) == nil)

        let first = TargetsModel(today: today)
        try first.load(profile: profiles.profile(), target: nil, latestWeightKg: profiles.latestWeight()?.kg)
        first.overrideKcal = true
        first.manualKcal = "2200"
        #expect(try first.save(to: profiles))
        let saved = try #require(try profiles.target(on: today))
        #expect(saved.kcal == 2200)

        let second = TargetsModel(today: today)
        try second.load(profile: profiles.profile(), target: saved, latestWeightKg: profiles.latestWeight()?.kg)
        #expect(try second.save(to: profiles))
        #expect(try profiles.target(on: today)?.macros == saved.macros)
        let weights = try #require(try env.portability?.exportCSV()["weights.csv"])
        #expect(weights.split(whereSeparator: \.isNewline).count == 2) // header + the one weigh-in
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

    @Test func `diary follows today across midnight`() {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = DiaryModel(environment: env)
        let firstDay = model.day
        clock.advance(hours: 24) // e.g. the app sat in the background overnight
        #expect(model.day == firstDay) // nothing changes until the app becomes active again
        env.refreshToday()
        #expect(model.day == firstDay.next)
        #expect(model.isToday)
    }

    @Test func `a day the user picked stays when the date changes`() {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = DiaryModel(environment: env)
        model.goToPreviousDay()
        let picked = model.day
        clock.advance(hours: 24)
        env.refreshToday()
        #expect(model.day == picked)
        model.goToToday()
        #expect(model.day == env.today)
        model.day = env.today.previous // the date picker sets `day` directly
        #expect(!model.isToday)
    }

    @Test func `undo is dropped after an import`() throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let entry = try #require(try env.diary?.log(food: food, quantity: .base(50), slotID: "breakfast", day: model.day))
        model.delete([entry])
        try env.dataDidChangeExternally()
        model.undo.performUndo() // the toast may still be up: undoing must not touch the imported data
        #expect(try env.diary?.diary(for: model.day).entryCount == 0)

        let second = try #require(try env.diary?.log(food: food, quantity: .base(20), slotID: "breakfast", day: model.day))
        model.delete([second])
        #expect(model.undo.current != nil)
        model.dataDidChangeExternally() // what the view does when the data generation changes
        #expect(model.undo.current == nil)
    }

    @Test func `move sheet offers the entry's inactive slot`() async throws {
        let (env, food) = try environment()
        let model = DiaryModel(environment: env)
        let entry = try #require(try env.diary?.log(food: food, quantity: .base(50), slotID: "lunch", day: model.day))
        let slots = try #require(try env.diary?.mealSlots(includeInactive: true)).map { slot in
            var copy = slot
            copy.isActive = slot.id != "lunch"
            return copy
        }
        try env.profiles?.saveMealSlots(slots)

        let observation = Task { await model.observeDiary() }
        defer { observation.cancel() }
        #expect(await waitUntil { model.diary?.entryCount == 1 })
        #expect(!model.slots.contains { $0.id == "lunch" })
        #expect(model.moveTargets(for: entry).map(\.id) == ["breakfast", "lunch", "dinner", "snacks"])
    }

    @Test func `observation restarts after an error`() async {
        struct Failure: Error {}
        var attempts = 0
        var values: [Int] = []
        var errors = 0
        await DiaryModel.resubscribing(retryDelay: .milliseconds(1)) {
            attempts += 1
            let attempt = attempts
            return AsyncThrowingStream<Int, Error> { continuation in
                if attempt < 3 {
                    continuation.finish(throwing: Failure())
                } else {
                    continuation.yield(42)
                    continuation.finish()
                }
            }
        } onValue: {
            values.append($0)
        } onError: {
            _ in errors += 1
        }
        #expect(attempts == 3)
        #expect(values == [42])
        #expect(errors == 1) // reported once per run of failures, not on every retry
    }

    @Test func `undo toast is announced and stays while VoiceOver runs`() async throws {
        var announcements: [String] = []
        let center = UndoCenter(duration: .milliseconds(20), isVoiceOverRunning: { true }, announce: { announcements.append($0) })
        center.offer("Deleted Oats") {}
        #expect(announcements == ["Deleted Oats. Undo available"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(center.current?.message == "Deleted Oats")
        center.dismiss()
        #expect(center.current == nil)
    }

    @Test func `undo center auto dismisses`() async throws {
        let center = UndoCenter(duration: .milliseconds(50), isVoiceOverRunning: { false }, announce: { _ in })
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

    @Test func `search rows know liquids`() throws {
        let milk = Food(name: "Milk", per100: Nutrients(kcal: 59, proteinG: 3.3, carbsG: 4.7, fatG: 2.8), isLiquid: true)
        let bread = Food(name: "Bread", per100: Nutrients(kcal: 240, proteinG: 8, carbsG: 44, fatG: 3))
        #expect(FoodSearchResult.food(milk).isLiquid)
        #expect(!FoodSearchResult.food(bread).isLiquid)
        let bundled = try #require(try BundledFoodIndex.inBundle(.main)?.search("rice", limit: 1).first)
        #expect(!FoodSearchResult.bundled(bundled).isLiquid)
    }
}
