import Core

/// The Health types Vitalion reads (SPEC §3.4, FR-40), with the explanation shown before the permission sheet.
/// Plain data so onboarding, tests and the fake work without HealthKit; `LiveHealthDataSource` maps each case
/// to its `HKObjectType`.
public enum HealthReadType: String, CaseIterable, Sendable, Identifiable {
    case stepCount
    case activeEnergyBurned
    case basalEnergyBurned
    case sleepAnalysis
    case bodyMass
    case bodyFatPercentage
    case restingHeartRate
    case heartRateVariabilitySDNN
    case dietaryWater
    case height
    case dateOfBirth
    case biologicalSex

    public enum Kind: Sendable {
        case quantity, category, characteristic
    }

    public var id: String {
        rawValue
    }

    public var kind: Kind {
        switch self {
        case .sleepAnalysis: .category
        case .dateOfBirth, .biologicalSex: .characteristic
        default: .quantity
        }
    }

    /// The HealthKit identifier, e.g. "HKQuantityTypeIdentifierStepCount".
    public var identifier: String {
        switch kind {
        case .quantity: "HKQuantityTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        case .category: "HKCategoryTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        case .characteristic: "HKCharacteristicTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// The `daily_metrics` value this type feeds; nil for profile characteristics.
    public var metric: HealthMetric? {
        switch self {
        case .stepCount: .steps
        case .activeEnergyBurned: .activeEnergy
        case .basalEnergyBurned: .basalEnergy
        case .sleepAnalysis: .sleep
        case .bodyMass: .weight
        case .bodyFatPercentage: .bodyFat
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariabilitySDNN: .hrv
        case .dietaryWater: .water
        case .height, .dateOfBirth, .biologicalSex: nil
        }
    }

    public var title: String {
        switch self {
        case .stepCount: String(localized: "Steps", bundle: .module)
        case .activeEnergyBurned: String(localized: "Active energy", bundle: .module)
        case .basalEnergyBurned: String(localized: "Resting energy", bundle: .module)
        case .sleepAnalysis: String(localized: "Sleep", bundle: .module)
        case .bodyMass: String(localized: "Weight", bundle: .module)
        case .bodyFatPercentage: String(localized: "Body fat", bundle: .module)
        case .restingHeartRate: String(localized: "Resting heart rate", bundle: .module)
        case .heartRateVariabilitySDNN: String(localized: "Heart rate variability", bundle: .module)
        case .dietaryWater: String(localized: "Water", bundle: .module)
        case .height: String(localized: "Height", bundle: .module)
        case .dateOfBirth: String(localized: "Date of birth", bundle: .module)
        case .biologicalSex: String(localized: "Sex", bundle: .module, comment: "Biological sex (Health data type)")
        }
    }

    /// Why Vitalion reads this type.
    public var explanation: String {
        switch self {
        case .stepCount:
            String(localized: "Today's steps next to your diary. Steps from Apple Watch and iPhone are counted once.", bundle: .module)
        case .activeEnergyBurned:
            String(localized: "Calories burned through activity, shown next to what you eat.", bundle: .module)
        case .basalEnergyBurned:
            String(localized: "Calories your body burns at rest; with active energy it shows your total burn.", bundle: .module)
        case .sleepAnalysis:
            String(localized: "Time asleep and in bed, with sleep stages, from your Apple Watch.", bundle: .module)
        case .bodyMass:
            String(localized: "Your morning weigh-in, for the weight trend and the adaptive calorie target.", bundle: .module)
        case .bodyFatPercentage:
            String(localized: "Body fat from your scale, shown alongside your weight.", bundle: .module)
        case .restingHeartRate:
            String(localized: "Recovery context from your Apple Watch. Informational only.", bundle: .module)
        case .heartRateVariabilitySDNN:
            String(localized: "Your overnight HRV average from Apple Watch, as recovery context. Informational only.", bundle: .module)
        case .dietaryWater:
            String(localized: "Water logged in other apps also counts toward your daily water goal.", bundle: .module)
        case .height:
            String(localized: "Used with your age, sex and weight to estimate your calorie needs.", bundle: .module)
        case .dateOfBirth:
            String(localized: "Your age, for the calorie needs estimate.", bundle: .module)
        case .biologicalSex:
            String(localized: "Used by the calorie needs formula (Mifflin-St Jeor).", bundle: .module)
        }
    }
}

/// The Health types Vitalion writes (SPEC §3.4, FR-42/43/46) through `HealthWriting`.
public enum HealthWriteType: String, CaseIterable, Sendable, Identifiable {
    case dietaryEnergyConsumed
    case dietaryProtein
    case dietaryCarbohydrates
    case dietaryFatTotal
    case dietaryFiber
    case dietarySugar
    case dietarySodium
    case dietaryWater
    case bodyMass
    case bodyFatPercentage

    public var id: String {
        rawValue
    }

    /// The HealthKit identifier, e.g. "HKQuantityTypeIdentifierDietaryProtein" (`healthkit_link.hk_type`).
    public var identifier: String {
        "HKQuantityTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    public var title: String {
        switch self {
        case .dietaryEnergyConsumed: String(localized: "Energy consumed", bundle: .module)
        case .dietaryProtein: String(localized: "Protein", bundle: .module)
        case .dietaryCarbohydrates: String(localized: "Carbohydrates", bundle: .module)
        case .dietaryFatTotal: String(localized: "Fat", bundle: .module, comment: "The macronutrient")
        case .dietaryFiber: String(localized: "Fiber", bundle: .module)
        case .dietarySugar: String(localized: "Sugar", bundle: .module)
        case .dietarySodium: String(localized: "Sodium", bundle: .module)
        case .dietaryWater: String(localized: "Water", bundle: .module)
        case .bodyMass: String(localized: "Weight", bundle: .module)
        case .bodyFatPercentage: String(localized: "Body fat", bundle: .module)
        }
    }

    /// What Vitalion writes and when.
    public var explanation: String {
        switch self {
        case .dietaryEnergyConsumed:
            String(localized: "The calories of each diary entry, updated when you edit or delete it.", bundle: .module)
        // One whole sentence per nutrient, so translations needn't fit a lowercased title into a fixed sentence.
        case .dietaryProtein:
            String(localized: "The protein of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietaryCarbohydrates:
            String(localized: "The carbohydrates of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietaryFatTotal:
            String(localized: "The fat of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietaryFiber:
            String(localized: "The fiber of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietarySugar:
            String(localized: "The sugar of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietarySodium:
            String(localized: "The sodium of each diary entry, updated when you edit or delete it.", bundle: .module)
        case .dietaryWater:
            String(localized: "Water you log in Vitalion.", bundle: .module)
        case .bodyMass:
            String(
                localized: "Only weights you enter by hand in Vitalion. Weights from your scale are never written back.",
                bundle: .module,
            )
        case .bodyFatPercentage:
            String(
                localized: "Only body fat you enter by hand with a weight in Vitalion. Values from your scale are never written back.",
                bundle: .module,
            )
        }
    }
}

public extension HealthReadType {
    /// The types read as individual samples.
    var sampledMetric: SampledMetric? {
        switch self {
        case .bodyMass: .bodyMass
        case .bodyFatPercentage: .bodyFatPercentage
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariabilitySDNN: .heartRateVariabilitySDNN
        default: nil
        }
    }
}
