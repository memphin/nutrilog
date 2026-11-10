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
    /// The latest weight (weigh-ins in Vitalion and Apple Health): read-only here, it is changed by weighing in (#65).
    private(set) var weightKg: Double?
    /// The day of that weight.
    private(set) var weightDay: LocalDay?

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

    // Field text as loaded. The fields round to 2 decimals / whole percent, so a field still showing its
    // loaded text means "unchanged" and the stored value is kept instead of the rounded one.
    private var loadedPercents: [String]?
    private var loadedGrams: [String]?
    private var loadedFiber: String?

    init(today: LocalDay) {
        self.today = today
    }

    // MARK: Loading

    func load(profile: Profile, target: Target?, latestWeightKg: Double?, weightDay: LocalDay? = nil) {
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
        weightKg = latestWeightKg.flatMap { $0 > 0 ? $0 : nil }
        self.weightDay = weightKg == nil ? nil : weightDay
        if let target {
            // A target from the weekly check-in is shown as it is, not replaced by the formula's suggestion.
            overrideKcal = target.origin != .formula
            manualKcal = Format.field(target.kcal)
            proteinG = Format.field(target.proteinG)
            carbsG = Format.field(target.carbsG)
            fatG = Format.field(target.fatG)
            fiberG = Format.field(target.fiberG)
            let split = MacroSplit(from: target.macros)
            proteinPct = Format.field(split.proteinPct.rounded())
            carbsPct = Format.field(split.carbsPct.rounded())
            fatPct = Format.field(100 - split.proteinPct.rounded() - split.carbsPct.rounded())
            loadedPercents = [proteinPct, carbsPct, fatPct]
            loadedGrams = [proteinG, carbsG, fatG]
            loadedFiber = fiberG
        }
    }

    // MARK: Calculation

    var age: Int? {
        guard hasBirthDate else { return nil }
        return Energy.age(birthDate: LocalDay(birthDate), on: today)
    }

    var bmr: Double? {
        guard let height = Format.number(heightCm), height > 0, let weight = weightKg,
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
        if let stored = currentTarget, keepsStoredMacros(stored) {
            return stored.macros
        }
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
                .append(overrideKcal ? "Enter a calorie target." : weightKg == nil
                    ? "Add a weight (Today → Weight) and fill in height, birth date and sex — or set calories manually."
                    : "Fill in height, birth date and sex — or set calories manually.")
        }
        if macroInput == .percent, split?.isValid != true {
            errors.append("Macro percentages must add up to 100 % (now \(Int(percentSum.rounded())) %).")
        }
        if macroInput == .grams, macros == nil {
            errors.append("Enter protein, carbs and fat in grams.")
        }
        return errors
    }

    /// True when the stored gram targets still apply: the macro fields of the current input mode are as
    /// loaded and, for percentages, the calorie target is unchanged. Without this, re-saving would turn the
    /// stored grams into the rounded percentages' grams.
    private func keepsStoredMacros(_ stored: Target) -> Bool {
        switch macroInput {
        case .percent:
            [proteinPct, carbsPct, fatPct] == loadedPercents && effectiveKcal?.rounded() == stored.kcal
        case .grams:
            [proteinG, carbsG, fatG] == loadedGrams
        }
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

    func makeTarget() -> Target? {
        guard validationErrors.isEmpty, let kcal = effectiveKcal, let macros else { return nil }
        let fiber = fiberG == loadedFiber ? currentTarget?.fiberG : Format.number(fiberG).flatMap { $0 > 0 ? $0 : nil }
        // Changing only macros or fiber keeps a check-in target "adaptive".
        let keepsAdaptive = overrideKcal && currentTarget?.origin == .adaptive && currentTarget?.kcal == kcal.rounded()
        return Target(
            effectiveFrom: today, kcal: kcal.rounded(), macros: macros, fiberG: fiber,
            origin: keepsAdaptive ? .adaptive : overrideKcal ? .manual : .formula,
        )
    }

    /// Saves the form. The target — the point of this screen, validated as a whole — is written first, then
    /// the profile only when it changed, so a failure leaves as little half-saved as possible.
    /// Returns false when the form is invalid (nothing is written).
    @discardableResult
    func save(to profiles: ProfileRepository) throws -> Bool {
        guard let target = makeTarget() else { return false }
        let profileToSave = updatedProfile().flatMap { $0 == profile ? nil : $0 }
        try profiles.setTarget(target)
        if let profileToSave {
            try profiles.save(profileToSave)
        }
        return true
    }
}
