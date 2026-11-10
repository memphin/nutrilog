import Core
import Foundation

/// VoiceOver labels of the dashboard tiles (FR-73), pure so they are unit-tested.
extension DashboardSnapshot {
    /// The spoken label of a tile, e.g. "Weight, 81.4 kilograms, trend 81.2, down 0.4 in 7 days" or
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
            var parts = ["\(number(weight.latestKg, digits: 1)) kilograms", "trend \(number(weight.trendKg, digits: 1))"]
            if let change = weight.trendChange7d {
                let rounded = (change * 10).rounded() / 10
                parts
                    .append(rounded == 0 ? "unchanged in 7 days" :
                        "\(rounded < 0 ? "down" : "up") \(number(abs(rounded), digits: 1)) in 7 days")
            }
            parts += [measured(weight.latest.day)].compactMap(\.self)
            return parts
        case .bodyFat:
            guard let bodyFat else { return [] }
            return ["\(number(bodyFat.pct, digits: 1)) percent"] + [measured(bodyFat.day)].compactMap(\.self)
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
            if tile == .hrv, let deviation = comparison.deviationText {
                parts.append(deviation)
            }
            parts += [measured(comparison.day)].compactMap(\.self)
            return parts
        case .water:
            return ["\(number(water.totalMl)) of \(number(water.goalMl)) millilitres", water.isGoalReached ? "goal reached" : "below goal"]
        }
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
        if let asleep = sleep?.asleepMin {
            return ["\(Self.spokenDuration(asleep)) asleep"]
        }
        return sleep?.inBedMin.map { ["\(Self.spokenDuration($0)) in bed"] } ?? []
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
