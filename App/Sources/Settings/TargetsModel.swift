import Core
import Foundation
import Observation
import Persistence

/// Profile form + calorie/macro target calculation (backlog #11, FR-30–33).
@MainActor
@Observable
final class TargetsModel {
    enum MacroInput: String, CaseIterable, Identifiable {
        case percent = "%"
        case grams = "g"
        var id: String {
            rawValue
        }
    }

    // Profile
    var heightCm = ""
    var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    var hasBirthDate = false
    var sex: Sex?
    var activity: ActivityLevel = .light
    var goal: GoalMode = .maintain
    var rateKgPerWeek = 0.5
    var weightKg = ""
    private(set) var storedWeightKg: Double?

    // Target
    var overrideKcal = false
    var manualKcal = ""
    var macroInput: MacroInput = .percent
    var proteinPct = "30"
    var carbsPct = "40"
    var fatPct = "30"
    var proteinG = ""
    var carbsG = ""
    var fatG = ""
    var fiberG = ""

    private(set) var profile: Profile?
    private(set) var currentTarget: Target?
    let today: LocalDay

    init(today: LocalDay) {
        self.today = today
    }

    // MARK: Loading

    func load(profile: Profile, target: Target?, latestWeightKg: Double?) {
        self.profile = profile
        currentTarget = target
        heightCm = Format.field(profile.heightCm)
        if let birth = profile.birthDate {
            birthDate = birth.startDate()
            hasBirthDate = true
        }
        sex = profile.sex
        activity = profile.activityLevel
        goal = profile.goalMode
        rateKgPerWeek = profile.goalRateKgPerWeek > 0 ? profile.goalRateKgPerWeek : 0.5
        storedWeightKg = latestWeightKg
        weightKg = Format.field(latestWeightKg)
        if let target {
            overrideKcal = target.origin == .manual
            manualKcal = Format.field(target.kcal)
            proteinG = Format.field(target.proteinG)
            carbsG = Format.field(target.carbsG)
            fatG = Format.field(target.fatG)
            fiberG = Format.field(target.fiberG)
            let split = MacroSplit(from: target.macros)
            proteinPct = Format.field(split.proteinPct.rounded())
            carbsPct = Format.field(split.carbsPct.rounded())
            fatPct = Format.field(100 - split.proteinPct.rounded() - split.carbsPct.rounded())
        }
    }

    // MARK: Calculation

    var age: Int? {
        guard hasBirthDate else { return nil }
        return Energy.age(birthDate: LocalDay(birthDate), on: today)
    }

    var bmr: Double? {
        guard let height = Format.number(heightCm), height > 0, let weight = Format.number(weightKg), weight > 0,
              let age, let sex else { return nil }
        return Energy.mifflinStJeor(weightKg: weight, heightCm: height, ageYears: Double(age), sex: sex)
    }

    var tdee: Double? {
        bmr.map { Energy.baselineTDEE(bmr: $0, activity: activity) }
    }

    var formulaKcal: Double? {
        tdee.map { Energy.calorieTarget(tdee: $0, goal: goal, rateKgPerWeek: goal == .maintain ? 0 : rateKgPerWeek) }
    }

    var dailyDelta: Double {
        Energy.dailyDelta(goal: goal, rateKgPerWeek: rateKgPerWeek)
    }

    /// The calorie target that will be saved.
    var effectiveKcal: Double? {
        overrideKcal ? Format.number(manualKcal).flatMap { $0 > 0 ? $0 : nil } : formulaKcal
    }

    var split: MacroSplit? {
        guard let p = Format.number(proteinPct), let c = Format.number(carbsPct), let f = Format.number(fatPct) else { return nil }
        return MacroSplit(proteinPct: p, carbsPct: c, fatPct: f)
    }

    var percentSum: Double {
        [proteinPct, carbsPct, fatPct].compactMap(Format.number).reduce(0, +)
    }

    var macros: MacroTargets? {
        switch macroInput {
        case .percent:
            guard let kcal = effectiveKcal, let split, split.isValid else { return nil }
            return split.grams(forKcal: kcal)
        case .grams:
            guard let p = Format.number(proteinG), let c = Format.number(carbsG), let f = Format.number(fatG),
                  p >= 0, c >= 0, f >= 0 else { return nil }
            return MacroTargets(proteinG: p, carbsG: c, fatG: f)
        }
    }

    var validationErrors: [String] {
        var errors: [String] = []
        if effectiveKcal == nil {
            errors
                .append(overrideKcal ? "Enter a calorie target." : "Fill in height, weight, birth date and sex — or set calories manually.")
        }
        if macroInput == .percent, split?.isValid != true {
            errors.append("Macro percentages must add up to 100 % (now \(Int(percentSum.rounded())) %).")
        }
        if macroInput == .grams, macros == nil {
            errors.append("Enter protein, carbs and fat in grams.")
        }
        if let weight = Format.number(weightKg), weight <= 0 || weight >= 500 {
            errors.append("Weight looks wrong.")
        }
        return errors
    }

    /// Gram targets' energy vs. the calorie target — shown as a hint in gram mode.
    var gramsEnergyMismatch: Double? {
        guard macroInput == .grams, let macros, let kcal = effectiveKcal, kcal > 0 else { return nil }
        return macros.kcal - kcal
    }

    // MARK: Saving

    func updatedProfile() -> Profile? {
        guard var profile else { return nil }
        profile.heightCm = Format.number(heightCm).flatMap { $0 > 0 ? $0 : nil }
        profile.birthDate = hasBirthDate ? LocalDay(birthDate) : nil
        profile.sex = sex
        profile.activityLevel = activity
        profile.goalMode = goal
        profile.goalRateKgPerWeek = goal == .maintain ? 0 : rateKgPerWeek
        return profile
    }

    /// New weight to store, when the field differs from the latest stored weight.
    var newWeight: Double? {
        guard let weight = Format.number(weightKg), weight > 0, weight < 500 else { return nil }
        if let stored = storedWeightKg, abs(stored - weight) < 0.001 {
            return nil
        }
        return weight
    }

    func makeTarget() -> Target? {
        guard validationErrors.isEmpty, let kcal = effectiveKcal, let macros else { return nil }
        let fiber = Format.number(fiberG).flatMap { $0 > 0 ? $0 : nil }
        return Target(
            effectiveFrom: today, kcal: kcal.rounded(), macros: macros, fiberG: fiber,
            origin: overrideKcal ? .manual : .formula,
        )
    }
}
