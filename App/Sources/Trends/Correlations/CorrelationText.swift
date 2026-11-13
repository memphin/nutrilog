import Core
import Foundation

/// Everything a correlation says in words: values with units, the strength, the "top against bottom third" sentence
/// and the chart's spoken summary. Sentences are put together from whole localized phrases, so a language can choose
/// its own word order and agreement (Croatian uses masculine subjects and gender-free conditions).
enum CorrelationText {
    // MARK: Values

    /// A value of `metric` in display units: "2.5 L", "1.75 L", "850 ml", "7 h 20 min", "9,800 steps", "2,350 kcal", "−0.3 kg/week".
    static func format(_ value: Double, _ metric: CorrelationMetric, unit: EnergyUnit) -> String {
        switch metric {
        case .calories, .totalEnergy, .activeEnergy: "\(Format.whole(value)) \(unit.symbol)"
        case .protein, .carbs, .fat: "\(Format.whole(value)) g"
        case .steps: "\(Format.whole(value)) \(ChartBuilder.unitLabel(.steps, unit: unit))"
        case .sleep: Format.duration(minutes: Int((value * 60).rounded()))
        case .hydration: litres(value)
        case .hrv: Format.ms(value)
        case .restingHeartRate: Format.bpm(value)
        case .weightTrendChange: perWeek(value)
        }
    }

    /// The size of a difference of `metric`, without a sign: "6 ms", "25 min", "300 ml".
    static func amount(_ difference: Double, _ metric: CorrelationMetric, unit: EnergyUnit) -> String {
        format(abs(difference), metric, unit: unit)
    }

    /// True when `difference` rounds to nothing in the way `format` shows it.
    static func isNegligible(_ difference: Double, _ metric: CorrelationMetric) -> Bool {
        let step = switch metric {
        case .sleep: 1.0 / 60 // a minute
        case .hydration: 0.001 // a millilitre
        case .weightTrendChange: 0.1
        default: 1.0
        }
        return abs(difference) < step / 2
    }

    /// The axis title: "Hydration (L)"; just "Steps" for steps.
    static func axisLabel(_ metric: CorrelationMetric, unit: EnergyUnit) -> String {
        metric == .steps ? metric.title : "\(metric.title) (\(unitLabel(metric, unit: unit)))"
    }

    static func unitLabel(_ metric: CorrelationMetric, unit: EnergyUnit) -> String {
        switch metric {
        case .calories, .totalEnergy, .activeEnergy: unit.symbol
        case .protein, .carbs, .fat: "g"
        case .steps: ChartBuilder.unitLabel(.steps, unit: unit)
        case .sleep: "h"
        case .hydration: "L"
        case .hrv: "ms"
        case .restingHeartRate: "bpm"
        case .weightTrendChange: String(localized: "kg/week", comment: "Unit of a weekly weight change")
        }
    }

    /// Litres from 1 L to the nearest 50 ml ("2.3 L", "1.75 L": quarter litres stay exact), millilitres below ("850 ml").
    private static func litres(_ value: Double) -> String {
        let rounded = (value * 20).rounded() / 20
        return rounded >= 1
            ? "\(rounded.formatted(.number.precision(.fractionLength(1 ... 2)))) L"
            : Format.ml(value * 1000)
    }

    /// "−0.3 kg/week", "+0.1 kg/week".
    private static func perWeek(_ value: Double) -> String {
        String(localized: "\(Format.kgChange(value))/week", comment: "A weekly weight change: \"−0.3 kg/week\"")
    }

    // MARK: Strength and sample

    /// "Moderate positive link", "No clear link", or "Not enough data" below the minimum sample.
    static func strength(_ result: CorrelationResult) -> String {
        guard let strength = result.strength else { return String(localized: "Not enough data") }
        return switch (strength, result.direction != .negative) {
        case (.none, _): String(localized: "No clear link")
        case (.weak, true): String(localized: "Weak positive link")
        case (.weak, false): String(localized: "Weak negative link")
        case (.moderate, true): String(localized: "Moderate positive link")
        case (.moderate, false): String(localized: "Moderate negative link")
        case (.strong, true): String(localized: "Strong positive link")
        case (.strong, false): String(localized: "Strong negative link")
        }
    }

    /// "Based on 42 days" / "Based on 12 weeks".
    static func basedOn(_ analysis: CorrelationAnalysis) -> String {
        let count = analysis.result.count
        return analysis.isWeekly ? String(localized: "Based on \(count) weeks") : String(localized: "Based on \(count) days")
    }

    /// "Needs 14 days with both values. You have 9."
    static func needs(_ analysis: CorrelationAnalysis) -> String {
        let required = analysis.result.minimumCount
        let count = analysis.result.count
        let needs = analysis.isWeekly
            ? String(localized: "Needs \(required) weeks with both values.")
            : String(localized: "Needs \(required) days with both values.")
        return "\(needs) \(String(localized: "You have \(count)."))"
    }

    // MARK: Sentence

    /// The card's sentence: the mean y of the top third by x against the bottom third, e.g. "On days you drank 2.5 L or
    /// more, your HRV the next day was 6 ms higher than on days under 1.8 L."; "Needs 14 days …" without enough pairs.
    static func sentence(_ analysis: CorrelationAnalysis) -> String {
        guard analysis.result.hasEnoughData else { return needs(analysis) }
        guard let thirds = analysis.result.thirds else { return String(localized: "There is too little variation to compare.") }
        let spec = analysis.spec, unit = analysis.unit
        let high = highCondition(spec, format(thirds.highFrom, spec.x, unit: unit))
        let low = lowCondition(spec, format(thirds.lowBelow, spec.x, unit: unit))
        let subject = subject(spec)
        if spec.y == .weightTrendChange {
            let highChange = format(thirds.highMeanY, .weightTrendChange, unit: unit)
            let lowChange = format(thirds.lowMeanY, .weightTrendChange, unit: unit)
            // "Changed by −0.1 kg/week, vs −0.1 kg/week" would read like a mistake.
            guard highChange != lowChange else { return String(localized: "\(high), \(subject) was about the same as \(low).") }
            return String(localized: "\(high), \(subject) changed by \(highChange), vs \(lowChange) \(low).")
        }
        let difference = thirds.difference
        if isNegligible(difference, spec.y) {
            return String(localized: "\(high), \(subject) was about the same as \(low).")
        }
        let size = amount(difference, spec.y, unit: unit)
        return switch (spec.y == .sleep, difference > 0) {
        case (true, true): String(localized: "\(high), \(subject) was \(size) longer than \(low).")
        case (true, false): String(localized: "\(high), \(subject) was \(size) shorter than \(low).")
        case (false, true): String(localized: "\(high), \(subject) was \(size) higher than \(low).")
        case (false, false): String(localized: "\(high), \(subject) was \(size) lower than \(low).")
        }
    }

    /// The top third: "On days you drank 2.5 L or more", "In weeks you averaged 9,800 steps or more".
    static func highCondition(_ spec: CorrelationSpec, _ value: String) -> String {
        spec.granularity == .weekly ? weeklyHighCondition(spec.x, value) : dailyHighCondition(spec.x, value)
    }

    private static func weeklyHighCondition(_ metric: CorrelationMetric, _ value: String) -> String {
        switch metric {
        case .calories, .steps: String(localized: "In weeks you averaged \(value) or more")
        case .protein: String(localized: "In weeks you averaged \(value) of protein or more")
        case .carbs: String(localized: "In weeks you averaged \(value) of carbs or more")
        case .fat: String(localized: "In weeks you averaged \(value) of fat or more")
        case .totalEnergy: String(localized: "In weeks your total energy averaged \(value) or more")
        case .activeEnergy: String(localized: "In weeks your active energy averaged \(value) or more")
        case .sleep: String(localized: "In weeks you averaged \(value) of sleep or more")
        case .hydration: String(localized: "In weeks your hydration averaged \(value) or more")
        case .hrv: String(localized: "In weeks your HRV averaged \(value) or more")
        case .restingHeartRate: String(localized: "In weeks your resting heart rate averaged \(value) or more")
        case .weightTrendChange: String(localized: "In weeks your weight trend changed by \(value) or more")
        }
    }

    private static func dailyHighCondition(_ metric: CorrelationMetric, _ value: String) -> String {
        switch metric {
        case .calories: String(localized: "On days you ate \(value) or more")
        case .protein: String(localized: "On days you ate \(value) of protein or more")
        case .carbs: String(localized: "On days you ate \(value) of carbs or more")
        case .fat: String(localized: "On days you ate \(value) of fat or more")
        case .steps: String(localized: "On days you walked \(value) or more")
        case .totalEnergy: String(localized: "On days you burned \(value) or more in total")
        case .activeEnergy: String(localized: "On days you burned \(value) or more of active energy")
        // A day's sleep is the night before it.
        case .sleep: String(localized: "After nights you slept \(value) or more")
        case .hydration: String(localized: "On days you drank \(value) or more")
        case .hrv: String(localized: "On days your HRV was \(value) or more")
        case .restingHeartRate: String(localized: "On days your resting heart rate was \(value) or more")
        case .weightTrendChange: String(localized: "In weeks your weight trend changed by \(value) or more")
        }
    }

    /// The bottom third: "on days under 1.8 L", "in weeks under 6,200 steps", "after nights under 6 h 30 min".
    static func lowCondition(_ spec: CorrelationSpec, _ value: String) -> String {
        if spec.granularity == .weekly {
            return String(localized: "in weeks under \(value)")
        }
        return spec.x == .sleep ? String(localized: "after nights under \(value)") : String(localized: "on days under \(value)")
    }

    /// What y is: "your HRV the next day", "your sleep that night", "your average step count", "your weight trend".
    static func subject(_ spec: CorrelationSpec) -> String {
        if spec.y == .weightTrendChange {
            return String(localized: "your weight trend")
        }
        if spec.y == .sleep {
            // Sleep is recorded on the morning it ends: a day's own sleep is the night before it.
            return switch (spec.granularity, spec.lag) {
            case (.weekly, _): String(localized: "your average sleep")
            case (.daily, .sameDay): String(localized: "your sleep the night before")
            case (.daily, .nextDay): String(localized: "your sleep that night")
            }
        }
        let noun = noun(spec.y)
        return switch (spec.granularity, spec.lag) {
        case (.weekly, _): String(localized: "your average \(noun)", comment: "The subject of a correlation sentence")
        case (.daily, .sameDay): String(localized: "your \(noun) that day", comment: "The subject of a correlation sentence")
        case (.daily, .nextDay): String(localized: "your \(noun) the next day", comment: "The subject of a correlation sentence")
        }
    }

    /// The measure as the subject of a sentence ("calorie intake", "step count").
    private static func noun(_ metric: CorrelationMetric) -> String {
        switch metric {
        case .calories: String(localized: "calorie intake")
        case .protein: String(localized: "protein intake")
        case .carbs: String(localized: "carb intake")
        case .fat: String(localized: "fat intake")
        case .steps: String(localized: "step count")
        case .totalEnergy: String(localized: "total energy burned")
        case .activeEnergy: String(localized: "active energy burned")
        case .hydration: String(localized: "hydration", comment: "Hydration as the subject of a sentence")
        case .hrv: String(localized: "HRV")
        case .restingHeartRate: String(localized: "resting heart rate")
        // Sleep and the weight trend have their own subjects (`subject(_:)`).
        case .sleep, .weightTrendChange: metric.title
        }
    }

    // MARK: Accessibility

    /// The scatter plot for VoiceOver: "Hydration against HRV, last 3 months. Based on 42 days. Moderate positive
    /// link. On days you drank …".
    static func chartSummary(_ analysis: CorrelationAnalysis) -> String {
        let x = analysis.spec.x.title, y = analysis.spec.y.title, period = analysis.period.spokenTitle
        return [
            String(localized: "\(x) against \(y), \(period)."),
            "\(basedOn(analysis)).",
            "\(strength(analysis.result)).",
            sentence(analysis),
        ].joined(separator: " ")
    }
}
