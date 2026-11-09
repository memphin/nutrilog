import Foundation

/// Biological sex as used by BMR formulas. `.other` uses the midpoint of the male/female constants.
public enum Sex: String, Sendable, Codable, CaseIterable {
    case male, female, other
}

/// Activity multipliers applied to BMR (standard Harris-Benedict / Mifflin factors).
public enum ActivityLevel: String, Sendable, Codable, CaseIterable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive = "very_active"

    public var factor: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }

    public var title: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Lightly active"
        case .moderate: "Moderately active"
        case .active: "Very active"
        case .veryActive: "Extremely active"
        }
    }

    public var explanation: String {
        switch self {
        case .sedentary: "Desk job, little or no exercise"
        case .light: "Light exercise 1–3 days a week"
        case .moderate: "Moderate exercise 3–5 days a week"
        case .active: "Hard exercise 6–7 days a week"
        case .veryActive: "Physical job plus hard training"
        }
    }
}

public enum GoalMode: String, Sendable, Codable, CaseIterable {
    case lose, maintain, gain

    /// Sign applied to the weekly rate (rate is stored as a positive magnitude).
    public var sign: Double {
        switch self {
        case .lose: -1
        case .maintain: 0
        case .gain: 1
        }
    }
}

/// Energy constants and formulas (SPEC §5.4, FR-31, FR-33).
public enum Energy {
    /// kcal per kg of body-weight change (SPEC §5.4.1 step 3).
    public static let kcalPerKg: Double = 7700

    /// Mifflin-St Jeor resting energy expenditure in kcal/day.
    /// `10·kg + 6.25·cm − 5·age + s`, s = +5 (male), −161 (female), −78 (other, midpoint).
    public static func mifflinStJeor(weightKg: Double, heightCm: Double, ageYears: Double, sex: Sex) -> Double {
        let s: Double = switch sex {
        case .male: 5
        case .female: -161
        case .other: -78
        }
        return 10 * weightKg + 6.25 * heightCm - 5 * ageYears + s
    }

    /// Formula-based maintenance estimate: BMR × activity factor.
    public static func baselineTDEE(bmr: Double, activity: ActivityLevel) -> Double {
        bmr * activity.factor
    }

    /// Daily energy delta for a weekly weight change goal, e.g. lose 0.5 kg/week → −550 kcal/day.
    public static func dailyDelta(goal: GoalMode, rateKgPerWeek: Double) -> Double {
        goal.sign * abs(rateKgPerWeek) * kcalPerKg / 7
    }

    /// Calorie target = maintenance + goal delta, rounded to 10 kcal.
    public static func calorieTarget(tdee: Double, goal: GoalMode, rateKgPerWeek: Double) -> Double {
        ((tdee + dailyDelta(goal: goal, rateKgPerWeek: rateKgPerWeek)) / 10).rounded() * 10
    }

    /// Age in whole years on `day`.
    public static func age(birthDate: LocalDay, on day: LocalDay) -> Int {
        var years = day.year - birthDate.year
        if (day.month, day.day) < (birthDate.month, birthDate.day) {
            years -= 1
        }
        return years
    }
}

/// Daily macro targets in grams.
public struct MacroTargets: Hashable, Sendable, Codable {
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double

    public init(proteinG: Double, carbsG: Double, fatG: Double) {
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    /// Energy these macros represent at 4/4/9.
    public var kcal: Double {
        proteinG * 4 + carbsG * 4 + fatG * 9
    }
}

/// Macro split as percentages of energy (FR-32).
public struct MacroSplit: Hashable, Sendable, Codable {
    public var proteinPct: Double
    public var carbsPct: Double
    public var fatPct: Double

    public init(proteinPct: Double, carbsPct: Double, fatPct: Double) {
        self.proteinPct = proteinPct
        self.carbsPct = carbsPct
        self.fatPct = fatPct
    }

    /// Default balanced split 30 / 40 / 30.
    public static let balanced = MacroSplit(proteinPct: 30, carbsPct: 40, fatPct: 30)

    /// Percentages must add up to 100 (±0.5 for rounding) and each be within 0…100.
    public var isValid: Bool {
        let parts = [proteinPct, carbsPct, fatPct]
        return parts.allSatisfy { (0 ... 100).contains($0) } && abs(parts.reduce(0, +) - 100) <= 0.5
    }

    /// Grams for a calorie target, rounded to whole grams.
    public func grams(forKcal kcal: Double) -> MacroTargets {
        MacroTargets(
            proteinG: (kcal * proteinPct / 100 / 4).rounded(),
            carbsG: (kcal * carbsPct / 100 / 4).rounded(),
            fatG: (kcal * fatPct / 100 / 9).rounded(),
        )
    }

    /// Percent split implied by gram targets (inverse of `grams(forKcal:)`).
    public init(from targets: MacroTargets) {
        let total = targets.kcal
        guard total > 0 else {
            self = .balanced
            return
        }
        proteinPct = targets.proteinG * 4 / total * 100
        carbsPct = targets.carbsG * 4 / total * 100
        fatPct = targets.fatG * 9 / total * 100
    }
}
