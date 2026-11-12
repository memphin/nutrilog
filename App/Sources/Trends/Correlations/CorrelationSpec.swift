import Core
import Foundation

/// A measure that can be compared with another (FR-53). Values come from `DayStats`, in display units.
enum CorrelationMetric: String, CaseIterable, Identifiable {
    case calories, protein, carbs, fat, steps, totalEnergy, activeEnergy, sleep, hydration, hrv, restingHeartRate
    /// The week's weight-trend change in kg/week; weekly only.
    case weightTrendChange

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .calories: String(localized: "Calories")
        case .protein: String(localized: "Protein")
        case .carbs: String(localized: "Carbs")
        case .fat: String(localized: "Fat", comment: "The macronutrient")
        case .steps: String(localized: "Steps")
        case .totalEnergy: String(localized: "Total energy")
        case .activeEnergy: String(localized: "Active energy")
        case .sleep: String(localized: "Sleep")
        case .hydration: String(localized: "Hydration")
        case .hrv: String(localized: "HRV")
        case .restingHeartRate: String(localized: "Resting heart rate")
        case .weightTrendChange: String(localized: "Weight-trend change")
        }
    }

    /// Diary intake: only fully logged days count (`DayStats.isLogged`, the maintenance estimate's rule).
    var isIntake: Bool {
        switch self {
        case .calories, .protein, .carbs, .fat: true
        default: false
        }
    }

    /// Weight-trend change is a change over a week; a day's change is mostly scale noise carried by the trend.
    var isWeeklyOnly: Bool {
        self == .weightTrendChange
    }

    /// The day's value in display units (energy in `unit`, sleep in hours, hydration in litres); nil when the day has
    /// none — for intake also when the day is only partly logged. Nil for weight-trend change (see `isWeeklyOnly`).
    func dailyValue(_ day: DayStats, unit: EnergyUnit) -> Double? {
        if isIntake, !day.isLogged {
            return nil
        }
        return switch self {
        case .calories: day.kcal.map(unit.display)
        case .protein: day.intake?.proteinG
        case .carbs: day.intake?.carbsG
        case .fat: day.intake?.fatG
        case .steps: day.steps.map(Double.init)
        case .totalEnergy: day.totalBurnedKcal.map(unit.display)
        case .activeEnergy: day.activeKcal.map(unit.display)
        case .sleep: day.sleepMin.map { Double($0) / 60 }
        case .hydration: day.waterMl.map { $0 / 1000 }
        case .hrv: day.hrvMs
        case .restingHeartRate: day.restingHR
        case .weightTrendChange: nil
        }
    }
}

/// Which day's y goes with a day's x.
enum CorrelationLag: String, CaseIterable, Identifiable {
    case sameDay, nextDay

    var id: String {
        rawValue
    }

    var days: Int {
        self == .sameDay ? 0 : 1
    }

    var title: String {
        switch self {
        case .sameDay: String(localized: "Same day")
        case .nextDay: String(localized: "Next day")
        }
    }
}

enum CorrelationGranularity: String, CaseIterable, Identifiable {
    case daily, weekly

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }
}

/// What is compared with what: the one input of the pair builder, shared by the cards and "Compare any two".
struct CorrelationSpec: Hashable {
    var x: CorrelationMetric
    var y: CorrelationMetric
    var lag: CorrelationLag = .sameDay
    var granularity: CorrelationGranularity = .daily

    /// Whether either side forces weeks (weight-trend change).
    var requiresWeekly: Bool {
        x.isWeeklyOnly || y.isWeeklyOnly
    }

    /// Weekly when a side requires it; a week is compared with the same week, so the lag is dropped.
    var normalized: CorrelationSpec {
        var spec = self
        if requiresWeekly {
            spec.granularity = .weekly
        }
        if spec.granularity == .weekly {
            spec.lag = .sameDay
        }
        return spec
    }

    /// Pairs needed before a link is described.
    var minimumPairs: Int {
        normalized.granularity == .weekly ? Correlation.minimumWeeklyPairs : Correlation.minimumDailyPairs
    }
}

/// The span of days the correlations look at.
enum CorrelationPeriod: String, CaseIterable, Identifiable {
    case threeMonths, sixMonths, year

    var id: String {
        rawValue
    }

    var dayCount: Int {
        switch self {
        case .threeMonths: 90
        case .sixMonths: 182
        case .year: 365
        }
    }

    var title: String {
        switch self {
        case .threeMonths: String(localized: "3 months")
        case .sixMonths: String(localized: "6 months")
        case .year: String(localized: "1 year")
        }
    }

    var spokenTitle: String {
        switch self {
        case .threeMonths: String(localized: "last 3 months")
        case .sixMonths: String(localized: "last 6 months")
        case .year: String(localized: "last year")
        }
    }

    /// The `dayCount` days ending yesterday: today is still going (its steps, hydration and intake keep growing).
    func days(before today: LocalDay) -> ClosedRange<LocalDay> {
        today.adding(days: -dayCount) ... today.previous
    }
}

/// The four insight cards on Trends.
enum CorrelationCard: String, CaseIterable, Identifiable {
    case hydrationHRV, hydrationSleep, stepsWeight, caloriesWeight

    var id: String {
        rawValue
    }

    var spec: CorrelationSpec {
        switch self {
        case .hydrationHRV: CorrelationSpec(x: .hydration, y: .hrv, lag: .nextDay)
        case .hydrationSleep: CorrelationSpec(x: .hydration, y: .sleep, lag: .nextDay)
        case .stepsWeight: CorrelationSpec(x: .steps, y: .weightTrendChange, granularity: .weekly)
        case .caloriesWeight: CorrelationSpec(x: .calories, y: .weightTrendChange, granularity: .weekly)
        }
    }

    var title: String {
        switch self {
        case .hydrationHRV: String(localized: "Hydration → HRV")
        case .hydrationSleep: String(localized: "Hydration → Sleep")
        case .stepsWeight: String(localized: "Steps → Weight")
        case .caloriesWeight: String(localized: "Calories → Weight")
        }
    }

    var systemImage: String {
        switch self {
        case .hydrationHRV: "waveform.path.ecg"
        case .hydrationSleep: "bed.double"
        case .stepsWeight: "figure.walk"
        case .caloriesWeight: "flame"
        }
    }
}
