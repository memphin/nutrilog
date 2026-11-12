import Core
import Foundation
import Observation
import Persistence

/// One number of the check-in with its explanation — every number on the sheet is tappable (SPEC §5.4.1 step 7).
struct CheckInFact: Identifiable, Equatable {
    enum Kind: String {
        case weeklyChange, goal, estimate, confidence, intake, baseline, currentTarget, proposal
    }

    var kind: Kind
    var title: String
    var value: String
    var explanation: String

    var id: String {
        kind.rawValue
    }
}

/// State and actions of the weekly check-in (backlog #35).
@MainActor
@Observable
final class CheckInModel {
    private(set) var snapshot: ExpenditureSnapshot?
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        reload()
    }

    var unit: EnergyUnit {
        environment.energyUnit
    }

    var estimate: TDEEEstimate? {
        try? snapshot?.estimate.get()
    }

    func reload() {
        do {
            snapshot = try Expenditure.snapshot(environment: environment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Decisions

    /// Applies the proposed target from today.
    @discardableResult
    func accept() -> Bool {
        guard let proposal = snapshot?.proposal else { return false }
        return record(.accepted, kcal: proposal.kcal)
    }

    /// Applies the user's own target from today.
    @discardableResult
    func applyEdited(kcal: Double) -> Bool {
        guard kcal.isFinite, kcal >= 500, kcal <= 10000 else {
            errorMessage = String(localized: "Enter a daily target between 500 and 10,000 kcal.")
            return false
        }
        return record(.edited, kcal: kcal.rounded())
    }

    /// Records the check-in and leaves the target alone.
    @discardableResult
    func skip() -> Bool {
        record(.skipped, kcal: nil)
    }

    /// The target written for `kcal`, fiber unchanged, effective today, origin adaptive. Its macros are the current
    /// target's: unchanged when the energy is, otherwise scaled by new / current kcal (whole grams). Without a current
    /// target (or with one of no energy) they are 25 / 45 / 30 or the current macros' split at the new energy.
    func makeTarget(kcal: Double) -> Target? {
        guard let snapshot else { return nil }
        return Target(
            effectiveFrom: snapshot.today, kcal: kcal, macros: Self.macros(forKcal: kcal, current: snapshot.currentTarget),
            fiberG: snapshot.currentTarget?.fiberG, origin: .adaptive,
        )
    }

    /// The macros of a check-in target at `kcal`: see `makeTarget(kcal:)`.
    static func macros(forKcal kcal: Double, current: Target?) -> MacroTargets {
        guard let current else { return MacroSplit.balanced.grams(forKcal: kcal) }
        if kcal == current.kcal {
            return current.macros
        }
        guard current.kcal.isFinite, current.kcal > 0, current.macros.kcal > 0 else {
            return MacroSplit(from: current.macros).grams(forKcal: kcal)
        }
        let factor = kcal / current.kcal
        return MacroTargets(
            proteinG: (current.proteinG * factor).rounded(),
            carbsG: (current.carbsG * factor).rounded(),
            fatG: (current.fatG * factor).rounded(),
        )
    }

    private func record(_ decision: CheckInDecision, kcal: Double?) -> Bool {
        guard let snapshot, let estimate, let proposal = snapshot.proposal, let checkIns = environment.checkIns else { return false }
        do {
            try checkIns.record(
                estimate: estimate, checkInDay: snapshot.today, proposedTargetKcal: proposal.kcal, decision: decision,
                appliedTarget: kcal.flatMap(makeTarget), previousTargetKcal: snapshot.currentTarget?.kcal,
                goalChangeKgPerWeek: snapshot.goalChangeKgPerWeek,
            )
            environment.widgetDataDidChange()
            reload()
            return true
        } catch {
            errorMessage = String(localized: "Couldn't save the check-in: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Facts

    var facts: [CheckInFact] {
        guard let snapshot, let estimate else { return [] }
        return Self.facts(
            estimate: estimate, proposal: snapshot.proposal, goalChangeKgPerWeek: snapshot.goalChangeKgPerWeek,
            currentTargetKcal: snapshot.currentTarget?.kcal, unit: unit,
        )
    }

    /// The numbers of a check-in (live or from history) with their explanations.
    static func facts(
        estimate: TDEEEstimate, proposal: TargetProposal?, goalChangeKgPerWeek: Double, currentTargetKcal: Double?, unit: EnergyUnit,
    ) -> [CheckInFact] {
        var facts = [
            CheckInFact(
                kind: .weeklyChange, title: String(localized: "Weight trend"),
                value: String(localized: "\(DashboardFormat.kgChange(estimate.weeklyChangeKg)) / week"),
                explanation: trendExplanation(estimate),
            ),
            CheckInFact(
                kind: .goal, title: String(localized: "Goal"),
                value: goalChangeKgPerWeek == 0
                    ? String(localized: "Maintain") : String(localized: "\(goalRate(goalChangeKgPerWeek)) / week"),
                explanation: goalExplanation(goalChangeKgPerWeek, unit: unit),
            ),
            CheckInFact(
                kind: .intake, title: String(localized: "Average intake"), value: unit.format(estimate.meanIntakeKcal),
                explanation: intakeExplanation(estimate),
            ),
            CheckInFact(
                kind: .estimate, title: String(localized: "Estimated maintenance"), value: unit.format(estimate.kcal),
                explanation: estimateExplanation(estimate, unit: unit),
            ),
            CheckInFact(
                kind: .confidence,
                title: String(localized: "Confidence"),
                value: estimate.confidence.title,
                explanation: confidenceExplanation(estimate),
            ),
        ]
        if let baseline = estimate.baselineKcal {
            facts.append(CheckInFact(
                kind: .baseline, title: String(localized: "Baseline"), value: unit.format(baseline),
                explanation: baselineExplanation,
            ))
        }
        if let currentTargetKcal {
            facts.append(CheckInFact(
                kind: .currentTarget, title: String(localized: "Current target"), value: unit.format(currentTargetKcal),
                explanation: String(localized: "The daily calorie target in effect today."),
            ))
        }
        if let proposal {
            facts.append(CheckInFact(
                kind: .proposal, title: String(localized: "Proposed target"), value: unit.format(proposal.kcal),
                explanation: proposalExplanation(proposal, estimate: estimate, goalChangeKgPerWeek: goalChangeKgPerWeek, unit: unit),
            ))
        }
        return facts
    }

    static func intakeExplanation(_ estimate: TDEEEstimate) -> String {
        String(localized: """
        The mean of your diary totals on the \(estimate.loggedDays) logged days of the last \(estimate.windowDays). \
        A day counts as logged with at least \(AdaptiveTDEE.minimumEntries) entries or when you marked it as fully \
        logged; other days are left out rather than counted as zero.
        """) + partialDaysSentence(estimate)
    }

    static var baselineExplanation: String {
        String(localized: """
        Your average total energy burned (active + resting) in Apple Health over the last \
        \(Energy.measuredWindowDays) days or, with less than \(Energy.measuredMinimumDays) days of it, the \
        Mifflin-St Jeor formula for your height, weight, age and sex times your activity level. The estimate \
        replaces this with your intake and weight trend; until confidence is high it is kept within 25 % of it.
        """)
    }

    /// Each method gets its own whole sentence, so a translation can reorder it freely.
    static func trendExplanation(_ estimate: TDEEEstimate) -> String {
        let startKg = kg2(estimate.trendStartKg), startDay = date(estimate.trendStartDay)
        let endKg = kg2(estimate.trendEndKg), endDay = date(estimate.day)
        let change = DashboardFormat.kgChange(estimate.trendChangeKg), days = estimate.trendSpanDays
        let weekly = DashboardFormat.kgChange(estimate.weeklyChangeKg)
        let measured = switch estimate.resolvedWeightMethod {
        case .trend:
            String(localized: """
            Your weight trend went from \(startKg) on \(startDay) to \(endKg) on \(endDay): \(change) in \(days) days, \
            which is \(weekly) per week.
            """)
        case .weighInLine:
            String(localized: """
            A straight line through your weigh-ins goes from \(startKg) on \(startDay) to \(endKg) on \(endDay): \
            \(change) in \(days) days, which is \(weekly) per week.
            """)
        }
        var text = measured + "\n\n" + String(localized: """
        The trend is a smoothed average of your weigh-ins (each daily one moves it by 10 %, one after a gap more), so \
        single heavy or light mornings barely show. Weigh-ins that jump more than 2.5 % from one day to the next count \
        even less.
        """)
        if estimate.resolvedWeightMethod == .weighInLine {
            text += "\n\n" + String(localized: """
            A young trend still lags behind your weigh-ins, so until it is \(AdaptiveTDEE.matureTrendDays) days old with \
            weigh-ins on at least \(AdaptiveTDEE.denseWeighIns) of the last \(AdaptiveTDEE.windowDays) days, the change is \
            measured with the line instead.
            """)
        }
        return text
    }

    /// " 1 partly logged day was left out too: …", or empty when none was.
    static func partialDaysSentence(_ estimate: TDEEEstimate) -> String {
        let count = estimate.partialDaysLeftOut
        guard count > 0 else { return "" }
        return " " + String(localized: """
        \(count) partly logged days were left out too: under half of your usual day and not marked as fully logged.
        """)
    }

    static func goalExplanation(_ goalChangeKgPerWeek: Double, unit: EnergyUnit) -> String {
        guard goalChangeKgPerWeek != 0 else {
            return String(localized: "Your goal is to keep your weight. Change it in Settings → Profile & targets.")
        }
        let daily = unit.format(abs(goalChangeKgPerWeek) * Energy.kcalPerKg / 7)
        return goalChangeKgPerWeek < 0
            ? String(localized: """
            Your goal from Settings → Profile & targets. One kilogram of body weight is counted as 7,700 kcal, so this \
            goal means eating \(daily) less than you burn every day.
            """)
            : String(localized: """
            Your goal from Settings → Profile & targets. One kilogram of body weight is counted as 7,700 kcal, so this \
            goal means eating \(daily) more than you burn every day.
            """)
    }

    static func estimateExplanation(_ estimate: TDEEEstimate, unit: EnergyUnit) -> String {
        let balance = estimate.dailyBalanceKcal
        let change = DashboardFormat.kgChange(estimate.trendChangeKg), days = estimate.trendSpanDays
        let perDay = unit.format(abs(balance))
        let stored = balance < 0
            ? String(localized: """
            Your weight changed by \(change) in \(days) days; at 7,700 kcal per kg that is \(perDay) a day taken from your \
            reserves.
            """)
            : String(localized: "Your weight changed by \(change) in \(days) days; at 7,700 kcal per kg that is \(perDay) a day stored.")
        // The sum itself is plain arithmetic of formatted values: nothing to translate.
        let sum = "\(unit.format(estimate.meanIntakeKcal)) \(balance < 0 ? "+" : "−") \(perDay) = \(unit.format(estimate.rawKcal))."
        var text = String(localized: "Maintenance = average intake − energy stored per day.") + "\n\n"
            + String(localized: "You ate \(unit.format(estimate.meanIntakeKcal)) a day.") + partialDaysSentence(estimate) + " "
            + estimate.resolvedWeightMethod.explanation + " " + stored + "\n\n" + sum
        if let previous = estimate.previousKcal {
            text += "\n\n" + String(localized: """
            To avoid jumps it is blended with the previous check-in's estimate (\(unit.format(previous))): 70 % new + \
            30 % old = \(unit.format(0.7 * estimate.rawKcal + 0.3 * previous)).
            """)
        }
        if estimate.wasClamped, let baseline = estimate.baselineKcal {
            text += "\n\n" + String(localized: """
            That is more than 25 % away from the baseline (\(unit.format(baseline))), so until confidence is high it is \
            limited to \(unit.format(estimate.kcal)).
            """)
        }
        if estimate.underLoggingSuspected {
            text += "\n\n" + String(localized: "This is unusually low for your body. The most common reason is food that wasn't logged.")
        }
        return text
    }

    static func confidenceExplanation(_ estimate: TDEEEstimate) -> String {
        String(localized: """
        \(estimate.loggedDays) of the last \(estimate.windowDays) days are logged and \(estimate.weighIns) have a weigh-in.
        """)
            + "\n\n" + String(localized: """
            High: at least \(AdaptiveTDEE.highConfidenceDays) days of history with 80 % of them logged, and a weight trend \
            at least \(AdaptiveTDEE.matureTrendDays) days old with weigh-ins on at least \(AdaptiveTDEE.denseWeighIns) of \
            the last \(AdaptiveTDEE.windowDays) days.
            """)
            + "\n" + String(localized: """
            Medium: at least \(AdaptiveTDEE.mediumLoggedDays) logged days and \(AdaptiveTDEE.mediumWeighIns) weigh-ins in \
            the last \(AdaptiveTDEE.windowDays) days.
            """)
            + "\n" + String(localized: "Low: anything less — treat the number as a rough guide.")
    }

    static func proposalExplanation(
        _ proposal: TargetProposal, estimate: TDEEEstimate, goalChangeKgPerWeek: Double, unit: EnergyUnit,
    ) -> String {
        let delta = goalChangeKgPerWeek * Energy.kcalPerKg / 7
        let maintenance = unit.format(estimate.kcal), computed = unit.format(proposal.computedKcal)
        let sign = delta < 0 ? "−" : "+", forGoal = unit.format(abs(delta))
        var text = if delta != 0 {
            String(localized: """
            Estimated maintenance \(maintenance) \(sign) \(forGoal) for your goal = \(computed) (rounded to 10 kcal).
            """)
        } else {
            String(localized: "Estimated maintenance \(maintenance) = \(computed) (rounded to 10 kcal).")
        }
        switch proposal.note {
        case .fromEstimate:
            break
        case .keptBecauseUnderLogging:
            text += "\n\n" + String(localized: """
            Your logged intake looks too low for your weight trend, so the app does not lower your target on this basis \
            and proposes keeping \(unit.format(proposal.kcal)). If your logging really is complete, use “Set my own” to \
            lower it.
            """)
        case .raisedToFloor:
            let floor = unit.format(AdaptiveTDEE.minimumTargetKcal)
            text += "\n\n" + String(localized: "That is below \(floor), the lowest target the app proposes.")
        }
        return text
    }

    /// "−0.25 kg": goal rates come in steps of 0.05.
    static func goalRate(_ value: Double) -> String {
        "\(value < 0 ? "−" : "+")\(abs(value).formatted(.number.precision(.fractionLength(1 ... 2)))) kg"
    }

    private static func kg2(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) kg"
    }

    private static func date(_ day: LocalDay) -> String {
        day.startDate().formatted(.dateTime.day().month(.abbreviated))
    }
}
