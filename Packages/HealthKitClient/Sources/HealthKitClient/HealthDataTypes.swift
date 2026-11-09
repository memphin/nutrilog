import Core

/// The Health types Nutrilog reads (SPEC §3.4, FR-40), with the explanation shown before the permission sheet.
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
        case .stepCount: "Steps"
        case .activeEnergyBurned: "Active energy"
        case .basalEnergyBurned: "Resting energy"
        case .sleepAnalysis: "Sleep"
        case .bodyMass: "Weight"
        case .bodyFatPercentage: "Body fat"
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariabilitySDNN: "Heart rate variability"
        case .dietaryWater: "Water"
        case .height: "Height"
        case .dateOfBirth: "Date of birth"
        case .biologicalSex: "Sex"
        }
    }

    /// Why Nutrilog reads this type.
    public var explanation: String {
        switch self {
        case .stepCount:
            "Today's steps next to your diary. Steps from Apple Watch and iPhone are counted once."
        case .activeEnergyBurned:
            "Calories burned through activity, shown next to what you eat."
        case .basalEnergyBurned:
            "Calories your body burns at rest; with active energy it shows your total burn."
        case .sleepAnalysis:
            "Time asleep and in bed, with sleep stages, from your Apple Watch."
        case .bodyMass:
            "Your morning weigh-in, for the weight trend and the adaptive calorie target."
        case .bodyFatPercentage:
            "Body fat from your scale, shown alongside your weight."
        case .restingHeartRate:
            "Recovery context from your Apple Watch. Informational only."
        case .heartRateVariabilitySDNN:
            "Your overnight HRV average from Apple Watch, as recovery context. Informational only."
        case .dietaryWater:
            "Water logged in other apps also counts toward your daily water goal."
        case .height:
            "Used with your age, sex and weight to estimate your calorie needs."
        case .dateOfBirth:
            "Your age, for the calorie needs estimate."
        case .biologicalSex:
            "Used by the calorie needs formula (Mifflin-St Jeor)."
        }
    }
}

/// The Health types Nutrilog writes (SPEC §3.4, FR-42/43/46) through `HealthWriting`.
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
        case .dietaryEnergyConsumed: "Energy consumed"
        case .dietaryProtein: "Protein"
        case .dietaryCarbohydrates: "Carbohydrates"
        case .dietaryFatTotal: "Fat"
        case .dietaryFiber: "Fiber"
        case .dietarySugar: "Sugar"
        case .dietarySodium: "Sodium"
        case .dietaryWater: "Water"
        case .bodyMass: "Weight"
        case .bodyFatPercentage: "Body fat"
        }
    }

    /// What Nutrilog writes and when.
    public var explanation: String {
        switch self {
        case .dietaryEnergyConsumed:
            "The calories of each diary entry, updated when you edit or delete it."
        case .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietaryFiber, .dietarySugar, .dietarySodium:
            "The \(title.lowercased()) of each diary entry, updated when you edit or delete it."
        case .dietaryWater:
            "Water you log in Nutrilog."
        case .bodyMass:
            "Only weights you enter by hand in Nutrilog. Weights from your scale are never written back."
        case .bodyFatPercentage:
            "Only body fat you enter by hand with a weight in Nutrilog. Values from your scale are never written back."
        }
    }
}

public extension HealthReadType {
    /// The types summed per day by statistics queries.
    var cumulativeMetric: CumulativeMetric? {
        switch self {
        case .stepCount: .steps
        case .activeEnergyBurned: .activeEnergy
        case .basalEnergyBurned: .basalEnergy
        case .dietaryWater: .dietaryWater
        default: nil
        }
    }

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
