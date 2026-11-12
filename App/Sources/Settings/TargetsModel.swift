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
    /// Maintenance measured from Apple Health energy (last 30 days); when present it replaces BMR × activity.
    private(set) var measured: MeasuredTDEE?

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

    /// `macrosInGrams`: the input mode of the last save (`macrosInGramsKey`), nil when never saved; without it the mode
    /// is inferred from the stored macros.
    func load(
        profile: Profile, target: Target?, latestWeightKg: Double?, weightDay: LocalDay? = nil, measured: MeasuredTDEE? = nil,
        macrosInGrams: Bool? = nil,
    ) {
        self.measured = measured
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
            let shown = MacroSplit(
                proteinPct: split.proteinPct.rounded(), carbsPct: split.carbsPct.rounded(),
                fatPct: 100 - split.proteinPct.rounded() - split.carbsPct.rounded(),
            )
            proteinPct = Format.field(shown.proteinPct)
            carbsPct = Format.field(shown.carbsPct)
            fatPct = Format.field(shown.fatPct)
            loadedPercents = [proteinPct, carbsPct, fatPct]
            loadedGrams = [proteinG, carbsG, fatG]
            loadedFiber = fiberG
            // Reopen in the mode the macros were entered in, so changing only the calories doesn't replace gram
            // targets with the rounded percentages' grams.
            if let macrosInGrams {
                macroInput = macrosInGrams ? .grams : .percent
            } else {
                macroInput = Self.matchesPercentSplit(target.macros, split: shown, kcal: target.kcal) ? .percent : .grams
            }
        }
    }

    /// Settings key (Bool): the macros of the last saved target were entered in grams.
    static let macrosInGramsKey = "targetsMacrosInGrams"

    /// True when `macros` are (within a gram, for rounding) what the whole-percent `split` gives at `kcal`, i.e. they
    /// could have been entered as percentages. Used to pick the input mode when none was saved.
    static func matchesPercentSplit(_ macros: MacroTargets, split: MacroSplit, kcal: Double) -> Bool {
        guard split.isValid, kcal > 0 else { return false }
        let fromSplit = split.grams(forKcal: kcal)
        return abs(fromSplit.proteinG - macros.proteinG) <= 1 && abs(fromSplit.carbsG - macros.carbsG) <= 1
            && abs(fromSplit.fatG - macros.fatG) <= 1
    }

    // MARK: Calculation

    var age: Int? {
        guard hasBirthDate else { return nil }
        return Energy.age(birthDate: LocalDay(birthDate), on: today)
    }

    /// Calorie targets the screen saves, manual or suggested (kcal; the field is always in kcal).
    static let kcalRange: ClosedRange<Double> = 500 ... 20000
    /// Each macro (and fiber) in grams.
    static let gramRange: ClosedRange<Double> = 0 ... 2000
    static let heightRange: ClosedRange<Double> = 50 ... 300

    var bmr: Double? {
        guard let height = Format.number(heightCm), Self.heightRange.contains(height), let weight = weightKg,
              let age, let sex else { return nil }
        return Energy.mifflinStJeor(weightKg: weight, heightCm: height, ageYears: Double(age), sex: sex)
    }

    /// Formula maintenance: BMR × activity, the fallback without enough Health energy.
    var formulaTDEE: Double? {
        bmr.map { Energy.baselineTDEE(bmr: $0, activity: activity) }
    }

    /// Maintenance the suggested target is built on: measured Health energy, or the formula without it.
    var tdee: Double? {
        measured?.kcal ?? formulaTDEE
    }

    var formulaKcal: Double? {
        tdee.map { Energy.calorieTarget(tdee: $0, goal: goal, rateKgPerWeek: goal == .maintain ? 0 : rateKgPerWeek) }
    }

    var dailyDelta: Double {
        Energy.dailyDelta(goal: goal, rateKgPerWeek: rateKgPerWeek)
    }

    /// The suggested target: `formulaKcal`, but never below the lowest target the weekly check-in proposes.
    var suggestedKcal: Double? {
        formulaKcal.flatMap { $0.isFinite ? max($0, AdaptiveTDEE.minimumTargetKcal) : nil }
    }

    /// True when maintenance ± the goal is below `AdaptiveTDEE.minimumTargetKcal`, so the suggestion is that minimum.
    var suggestionRaisedToFloor: Bool {
        formulaKcal.map { $0 < AdaptiveTDEE.minimumTargetKcal } ?? false
    }

    /// The calorie target that will be saved: always within `kcalRange` (so never ≤ 0), nil otherwise.
    var effectiveKcal: Double? {
        let kcal = overrideKcal ? Format.number(manualKcal) : suggestedKcal
        return kcal.flatMap { Self.kcalRange.contains($0) ? $0 : nil }
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
                  [p, c, f].allSatisfy({ Self.gramRange.contains($0) }) else { return nil }
            return MacroTargets(proteinG: p, carbsG: c, fatG: f)
        }
    }

    var validationErrors: [String] {
        var errors: [String] = []
        // Non-empty text that doesn't parse ("1e30", 25 digits, "inf": `Format.number` rejects those) gets the range
        // message, like a number that parses but is out of range; only an empty field asks for a value.
        if !Self.isBlank(heightCm), !Self.inRange(heightCm, Self.heightRange) {
            errors.append(String(localized: "Enter a height between 50 and 300 cm."))
        }
        if effectiveKcal == nil {
            if overrideKcal {
                let lowest = Self.kcalRange.lowerBound.formatted(), highest = Self.kcalRange.upperBound.formatted()
                errors.append(Self.isBlank(manualKcal)
                    ? String(localized: "Enter a calorie target.")
                    : String(localized: "Enter a daily target between \(lowest) and \(highest) kcal."))
            } else if suggestedKcal != nil {
                let highest = Self.kcalRange.upperBound.formatted()
                errors.append(String(localized: """
                The suggested target is above \(highest) kcal. Check your height, or set calories manually.
                """))
            } else {
                errors.append(weightKg == nil
                    ? String(localized: "Add a weight (Today → Weight) and fill in height, birth date and sex — or set calories manually.")
                    : String(localized: "Fill in height, birth date and sex — or set calories manually."))
            }
        }
        switch macroInput {
        case .percent:
            let filled = [proteinPct, carbsPct, fatPct].filter { !Self.isBlank($0) }
            if !filled.allSatisfy({ Self.inRange($0, 0 ... 100) }) {
                errors.append(String(localized: "Each macro percentage must be between 0 and 100."))
            } else if split?.isValid != true {
                errors.append(String(localized: "Macro percentages must add up to 100 % (now \(DisplayRounding.whole(percentSum)) %)."))
            }
        case .grams:
            let fields = [proteinG, carbsG, fatG]
            if fields.contains(where: Self.isBlank) {
                errors.append(String(localized: "Enter protein, carbs and fat in grams."))
            } else if !fields.allSatisfy({ Self.inRange($0, Self.gramRange) }) {
                let highest = Self.gramRange.upperBound.formatted()
                errors.append(String(localized: "Protein, carbs and fat must each be between 0 and \(highest) g."))
            }
        }
        // Fiber is optional and ≤ 0 means none; text that doesn't parse would otherwise be dropped silently.
        if fiberG != loadedFiber, !Self.isBlank(fiberG), Format.number(fiberG).map({ $0 > Self.gramRange.upperBound }) ?? true {
            errors.append(String(localized: "Fiber must be a number up to \(Self.gramRange.upperBound.formatted()) g."))
        }
        return errors
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when `text` parses to a number within `range` (false for text `Format.number` rejects).
    private static func inRange(_ text: String, _ range: ClosedRange<Double>) -> Bool {
        Format.number(text).map { range.contains($0) } ?? false
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
        // Only a convenience for the next visit (the mode is otherwise inferred), so a failure here isn't an error.
        try? profiles.setSetting(Self.macrosInGramsKey, macroInput == .grams)
        return true
    }
}
