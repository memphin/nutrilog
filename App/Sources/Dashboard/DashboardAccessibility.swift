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
            return steps.map { ["\(number(Double($0))) steps"] } ?? []
        case .sleep:
            guard let sleep else { return [] }
            var parts: [String] = []
            if let asleep = sleep.asleepMin {
                parts.append("\(Self.spokenDuration(asleep)) asleep")
            }
            if let inBed = sleep.inBedMin {
                parts.append("\(Self.spokenDuration(inBed)) in bed")
            }
            let stages: [(String, Int?)] = [("core", sleep.coreMin), ("deep", sleep.deepMin), ("REM", sleep.remMin), ("awake", sleep.awakeMin)]
            parts += stages.compactMap { name, minutes in minutes.map { "\(name) \(Self.spokenDuration($0))" } }
            return parts
        case .weight:
            guard let weight else { return [] }
            var parts = ["\(number(weight.latestKg, digits: 1)) kilograms", "trend \(number(weight.trendKg, digits: 1))"]
            if let change = weight.trendChange7d {
                let rounded = (change * 10).rounded() / 10
                parts.append(rounded == 0 ? "unchanged in 7 days" : "\(rounded < 0 ? "down" : "up") \(number(abs(rounded), digits: 1)) in 7 days")
            }
            parts += [measured(weight.latest.day)].compactMap(\.self)
            return parts
        case .bodyFat:
            guard let bodyFat else { return [] }
            return ["\(number(bodyFat.pct, digits: 1)) percent"] + [measured(bodyFat.day)].compactMap(\.self)
        case .activeEnergy:
            return activeKcal.map { ["\(number(energyUnit.display($0))) \(spokenEnergy)"] } ?? []
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
            return ["\(number(water.totalMl)) of \(number(water.goalMl)) millilitres"]
        }
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
