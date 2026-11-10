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
            errorMessage = "Enter a daily target between 500 and 10,000 kcal."
            return false
        }
        return record(.edited, kcal: kcal.rounded())
    }

    /// Records the check-in and leaves the target alone.
    @discardableResult
    func skip() -> Bool {
        record(.skipped, kcal: nil)
    }

    /// The target written for `kcal`: the current target's macro split (30 / 40 / 30 without one) at the new
    /// energy, fiber unchanged, effective today, origin adaptive.
    func makeTarget(kcal: Double) -> Target? {
        guard let snapshot else { return nil }
        let split = snapshot.currentTarget.map { MacroSplit(from: $0.macros) } ?? .balanced
        return Target(
            effectiveFrom: snapshot.today, kcal: kcal, macros: split.grams(forKcal: kcal),
            fiberG: snapshot.currentTarget?.fiberG, origin: .adaptive,
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
            errorMessage = "Couldn't save the check-in: \(error.localizedDescription)"
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
                kind: .weeklyChange, title: "Weight trend", value: "\(DashboardFormat.kgChange(estimate.weeklyChangeKg)) / week",
                explanation: trendExplanation(estimate),
            ),
            CheckInFact(
                kind: .goal, title: "Goal",
                value: goalChangeKgPerWeek == 0 ? "Maintain" : "\(goalRate(goalChangeKgPerWeek)) / week",
                explanation: goalExplanation(goalChangeKgPerWeek, unit: unit),
            ),
            CheckInFact(
                kind: .intake, title: "Average intake", value: unit.format(estimate.meanIntakeKcal),
                explanation: "The mean of your diary totals on the \(estimate.loggedDays) logged days of the last "
                    + "\(estimate.windowDays). A day counts as logged with at least \(AdaptiveTDEE.minimumEntries) entries or when you "
                    + "marked it as fully logged; other days are left out rather than counted as zero.",
            ),
            CheckInFact(
                kind: .estimate, title: "Estimated maintenance", value: unit.format(estimate.kcal),
                explanation: estimateExplanation(estimate, unit: unit),
            ),
            CheckInFact(
                kind: .confidence,
                title: "Confidence",
                value: estimate.confidence.title,
                explanation: confidenceExplanation(estimate),
            ),
        ]
        if let baseline = estimate.baselineKcal {
            facts.append(CheckInFact(
                kind: .baseline, title: "Formula baseline", value: unit.format(baseline),
                explanation: "What the Mifflin-St Jeor formula gives for your height, weight, age and sex, times your activity "
                    + "level. The estimate replaces this guess with your own data; until confidence is high it is kept within "
                    + "25 % of it.",
            ))
        }
        if let currentTargetKcal {
            facts.append(CheckInFact(
                kind: .currentTarget, title: "Current target", value: unit.format(currentTargetKcal),
                explanation: "The daily calorie target in effect today.",
            ))
        }
        if let proposal {
            facts.append(CheckInFact(
                kind: .proposal, title: "Proposed target", value: unit.format(proposal.kcal),
                explanation: proposalExplanation(proposal, estimate: estimate, goalChangeKgPerWeek: goalChangeKgPerWeek, unit: unit),
            ))
        }
        return facts
    }

    static func trendExplanation(_ estimate: TDEEEstimate) -> String {
        "Your weight trend went from \(kg2(estimate.trendStartKg)) on \(date(estimate.trendStartDay)) to "
            + "\(kg2(estimate.trendEndKg)) on \(date(estimate.day)): \(DashboardFormat.kgChange(estimate.trendChangeKg)) in "
            + "\(estimate.trendSpanDays) days, which is \(DashboardFormat.kgChange(estimate.weeklyChangeKg)) per week.\n\n"
            + "The trend is a smoothed average of your weigh-ins (each one moves it by 10 %), so single heavy or light "
            + "mornings barely show. Weigh-ins that jump more than 2.5 % from one day to the next count even less."
    }

    static func goalExplanation(_ goalChangeKgPerWeek: Double, unit: EnergyUnit) -> String {
        guard goalChangeKgPerWeek != 0 else {
            return "Your goal is to keep your weight. Change it in Settings → Profile & targets."
        }
        return "Your goal from Settings → Profile & targets. One kilogram of body weight is counted as 7,700 kcal, so "
            + "this goal means eating \(unit.format(abs(goalChangeKgPerWeek) * Energy.kcalPerKg / 7)) "
            + "\(goalChangeKgPerWeek < 0 ? "less" : "more") than you burn every day."
    }

    static func estimateExplanation(_ estimate: TDEEEstimate, unit: EnergyUnit) -> String {
        let balance = estimate.dailyBalanceKcal
        var text = "Maintenance = average intake − energy stored per day.\n\n"
            + "You ate \(unit.format(estimate.meanIntakeKcal)) a day. Your trend changed by "
            + "\(DashboardFormat.kgChange(estimate.trendChangeKg)) in \(estimate.trendSpanDays) days; at 7,700 kcal per kg that is "
            + "\(unit.format(abs(balance))) a day \(balance < 0 ? "taken from your reserves" : "stored").\n\n"
            + "\(unit.format(estimate.meanIntakeKcal)) \(balance < 0 ? "+" : "−") \(unit.format(abs(balance))) = \(unit.format(estimate.rawKcal))."
        if let previous = estimate.previousKcal {
            text += "\n\nTo avoid jumps it is blended with the previous check-in's estimate (\(unit.format(previous))): "
                + "70 % new + 30 % old = \(unit.format(0.7 * estimate.rawKcal + 0.3 * previous))."
        }
        if estimate.wasClamped, let baseline = estimate.baselineKcal {
            text += "\n\nThat is more than 25 % away from the formula baseline (\(unit.format(baseline))), so until confidence is "
                + "high it is limited to \(unit.format(estimate.kcal))."
        }
        if estimate.underLoggingSuspected {
            text += "\n\nThis is unusually low for your body. The most common reason is food that wasn't logged."
        }
        return text
    }

    static func confidenceExplanation(_ estimate: TDEEEstimate) -> String {
        "\(estimate.loggedDays) of the last \(estimate.windowDays) days are logged and \(estimate.weighIns) have a weigh-in.\n\n"
            + "High: at least \(AdaptiveTDEE.highConfidenceDays) days of history with 80 % of them logged.\n"
            + "Medium: at least \(AdaptiveTDEE.mediumLoggedDays) logged days and \(AdaptiveTDEE.mediumWeighIns) weigh-ins in the "
            + "last \(AdaptiveTDEE.windowDays) days.\nLow: anything less — treat the number as a rough guide."
    }

    static func proposalExplanation(
        _ proposal: TargetProposal, estimate: TDEEEstimate, goalChangeKgPerWeek: Double, unit: EnergyUnit,
    ) -> String {
        let delta = goalChangeKgPerWeek * Energy.kcalPerKg / 7
        var text = "Estimated maintenance \(unit.format(estimate.kcal))"
        if delta != 0 {
            text += " \(delta < 0 ? "−" : "+") \(unit.format(abs(delta))) for your goal"
        }
        text += " = \(unit.format(proposal.computedKcal)) (rounded to 10 kcal)."
        switch proposal.note {
        case .fromEstimate:
            break
        case .keptBecauseUnderLogging:
            text += "\n\nYour logged intake looks too low for your weight trend, so the app does not lower your target on "
                + "this basis and proposes keeping \(unit.format(proposal.kcal)). If your logging really is complete, use "
                + "“Set my own” to lower it."
        case .raisedToFloor:
            text += "\n\nThat is below \(unit.format(AdaptiveTDEE.minimumTargetKcal)), the lowest target the app proposes."
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
