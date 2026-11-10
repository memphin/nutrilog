import Core
import Foundation

/// VoiceOver labels of the dashboard tiles (FR-73), pure so they are unit-tested.
extension DashboardSnapshot {
    /// The spoken label of a tile, e.g. "Weight, 81.4 kilograms" or
    /// "Steps, no data. No data found — check Health permissions".
    func accessibilityLabel(of tile: DashboardTile, state: TileState, energyUnit: EnergyUnit = .kcal) -> String {
        guard state == .ready else {
            return "\(tile.title), no data. \(state.message ?? "")"
        }
        let parts = accessibilityParts(of: tile, energyUnit: energyUnit)
        return ([tile.title] + (parts.isEmpty ? ["no data"] : parts)).joined(separator: ", ")
    }

    private func accessibilityParts(of tile: DashboardTile, energyUnit: EnergyUnit) -> [String] {
        let spokenEnergy = energyUnit == .kcal ? "calories" : "kilojoules"
        func number(_ value: Double, digits: Int = 0) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
        }
        func measured(_ value: LocalDay) -> String? {
            value == today ? nil : "measured \(Format.day(value, today: today))"
        }
        switch tile {
        case .energy:
            var parts: [String] = []
            if let target {
                let remaining = target.kcal - totals.kcal
                parts.append(remaining >= 0
                    ? "\(number(energyUnit.display(remaining))) \(spokenEnergy) left of \(number(energyUnit.display(target.kcal)))"
                    : "\(number(energyUnit.display(-remaining))) \(spokenEnergy) over target")
            } else {
                parts.append("\(number(energyUnit.display(totals.kcal))) \(spokenEnergy) eaten")
            }
            parts.append("protein \(number(totals.proteinG)) grams, carbs \(number(totals.carbsG)) grams, fat \(number(totals.fatG)) grams")
            return parts
        case .steps:
            return stepsParts(number)
        case .sleep:
            return sleepParts
        case .weight:
            guard let weight else { return [] }
            // Like the tile: the weight only (#73); the trend is in the detail.
            return ["\(number(weight.latestKg, digits: 1)) kilograms"]
                + [weeklyParts(weight.latestKg, average: weeklyWeightKg), measured(weight.latest.day)].compactMap(\.self)
        case .bodyFat:
            guard let bodyFat else { return [] }
            return ["\(number(bodyFat.pct, digits: 1)) percent"]
                + [weeklyParts(bodyFat.pct, average: weeklyBodyFatPct), measured(bodyFat.day)].compactMap(\.self)
        case .totalEnergy:
            guard let burned = energyBurned else { return [] }
            if let total = burned.totalKcal, let active = burned.activeKcal, let resting = burned.restingKcal {
                return [
                    "\(number(energyUnit.display(total))) \(spokenEnergy)",
                    "active \(number(energyUnit.display(active)))",
                    "resting \(number(energyUnit.display(resting)))",
                ]
            }
            // Only one part is known: say which, and that there is no total.
            func part(_ value: Double?, _ name: String) -> String {
                value.map { "\(name) \(number(energyUnit.display($0))) \(spokenEnergy)" } ?? "\(name) energy unknown"
            }
            return [part(burned.activeKcal, "active"), part(burned.restingKcal, "resting"), "no total yet"]
        case .restingHeartRate, .hrv:
            guard let comparison = tile == .hrv ? hrv : restingHR else { return [] }
            let unit = tile == .hrv ? "milliseconds" : "beats per minute"
            var parts = ["\(number(comparison.value)) \(unit)", "7-day average \(number(comparison.average7))"]
            // The value's colour is read against the 30-day average (#74), so say where it stands.
            if let deviation = comparison.deviationText {
                parts.append(deviation)
            }
            parts += [measured(comparison.day)].compactMap(\.self)
            return parts
        case .water:
            return ["\(number(water.totalMl)) of \(number(water.goalMl)) millilitres", waterGoalPart]
        }
    }

    private var waterGoalPart: String {
        switch WaterGoal.band(ml: water.totalMl, goalMl: water.goalMl) {
        case .reached: "goal reached"
        case .near: "close to the goal"
        case .far: "below goal"
        }
    }

    /// "above the weekly average" — what the value's colour is read against; nil without a weekly average.
    private func weeklyParts(_ value: Double, average: Double?) -> String? {
        guard let average else { return nil }
        let difference = ((value - average) * 10).rounded() / 10
        return difference == 0 ? "at the weekly average" : "\(difference < 0 ? "below" : "above") the weekly average"
    }

    /// "8,500 steps", "close to the goal of 10,000".
    private func stepsParts(_ number: (Double, Int) -> String) -> [String] {
        guard let steps else { return [] }
        let goalText = number(Double(stepGoal), 0)
        let goal = switch StepGoal.band(steps: Double(steps), goal: stepGoal) {
        case .reached: "goal of \(goalText) reached"
        case .near: "close to the goal of \(goalText)"
        case .far: "below the goal of \(goalText)"
        }
        return ["\(number(Double(steps), 0)) steps", goal]
    }

    /// Like the tile: time asleep only; time in bed when that is all Health has. Stages are in the detail (#62).
    private var sleepParts: [String] {
        guard let minutes = sleepMinutes else { return [] }
        let goalText = Self.spokenDuration(sleepGoalMin)
        let goal = switch SleepGoal.band(minutes: Double(minutes), goal: sleepGoalMin) {
        case .reached: "goal of \(goalText) reached"
        case .near: "close to the goal of \(goalText)"
        case .far: "below the goal of \(goalText)"
        }
        return ["\(Self.spokenDuration(minutes)) \(sleep?.asleepMin == nil ? "in bed" : "asleep")", goal]
    }

    /// The tile's 7-day trend for VoiceOver ("up over 7 days"), spoken as the tile's value; nil without a chart or
    /// when the tile shows no value.
    func accessibilityTrend(of tile: DashboardTile, state: TileState) -> String? {
        guard state == .ready else { return nil }
        return sparkline(for: tile)?.accessibilitySummary
    }

    /// "7 hours 5 minutes", "45 minutes".
    static func spokenDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = rest == 1 ? "1 minute" : "\(rest) minutes"
        if hours == 0 {
            return minuteText
        }
        return rest == 0 ? hourText : "\(hourText) \(minuteText)"
    }
}
