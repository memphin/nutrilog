import Core
import Foundation

/// VoiceOver labels of the dashboard tiles (FR-73), pure so they are unit-tested.
extension DashboardSnapshot {
    /// The spoken label of a tile, e.g. "Weight, 81.4 kilograms" or
    /// "Steps, no data. No data found — check Health permissions". Whole phrases from the string catalog, numbers in
    /// `locale` (whole counts as integers so the catalog can pick the plural form).
    /// - Parameter now: the moment caffeine and hydration are read at (the caffeine amount and the hydration status
    ///   change by the minute).
    func accessibilityLabel(
        of tile: DashboardTile, state: TileState, energyUnit: EnergyUnit = .kcal, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current,
    ) -> String {
        guard state == .ready else {
            return String(localized: "\(tile.title), no data. \(state.message ?? "")", locale: locale)
        }
        if tile == .caffeine {
            return ([tile.title] + caffeineStatus(now: now, calendar: calendar).accessibilityParts(locale: locale)).joined(separator: ", ")
        }
        let spokenStreak = streak(for: tile).flatMap { StreakBadge.spoken($0, locale: locale) }
        if tile == .water {
            let parts = hydrationParts(hydrationDay(now: now, calendar: calendar), locale: locale)
            return ([tile.title] + parts + [spokenStreak].compactMap(\.self)).joined(separator: ", ")
        }
        let parts = accessibilityParts(of: tile, energyUnit: energyUnit, locale: locale)
        let noData = String(localized: "no data", locale: locale)
        return ([tile.title] + (parts.isEmpty ? [noData] : parts) + [spokenStreak].compactMap(\.self)).joined(separator: ", ")
    }

    /// A whole number to speak, rounded like `.number.precision(.fractionLength(0))` (half to even), as an `Int` so
    /// the localized phrase can pick its plural form. `DisplayRounding.whole` clamps what `Int` can't hold.
    private static func count(_ value: Double) -> Int {
        DisplayRounding.whole(value.rounded(.toNearestOrEven))
    }

    private func accessibilityParts(of tile: DashboardTile, energyUnit: EnergyUnit, locale: Locale) -> [String] {
        let isKcal = energyUnit == .kcal
        func energy(_ kcal: Double) -> Int {
            Self.count(energyUnit.display(kcal))
        }
        func decimal(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        }
        func measured(_ value: LocalDay) -> String? {
            value == today ? nil
                : String(localized: "measured \(Format.day(value, today: today, locale: locale))", locale: locale)
        }
        switch tile {
        case .energy:
            var parts: [String] = []
            if let target {
                let remaining = target.kcal - totals.kcal
                if remaining >= 0 {
                    let left = energy(remaining)
                    let goal = energy(target.kcal)
                    parts.append(isKcal
                        ? String(localized: "\(left) calories left of \(goal)", locale: locale)
                        : String(localized: "\(left) kilojoules left of \(goal)", locale: locale))
                } else {
                    let over = energy(-remaining)
                    parts.append(isKcal
                        ? String(localized: "\(over) calories over target", locale: locale)
                        : String(localized: "\(over) kilojoules over target", locale: locale))
                }
            } else {
                let eaten = energy(totals.kcal)
                parts.append(isKcal
                    ? String(localized: "\(eaten) calories eaten", locale: locale)
                    : String(localized: "\(eaten) kilojoules eaten", locale: locale))
            }
            let protein = Self.count(totals.proteinG)
            let carbs = Self.count(totals.carbsG)
            let fat = Self.count(totals.fatG)
            parts.append(String(localized: "protein \(protein) grams, carbs \(carbs) grams, fat \(fat) grams", locale: locale))
            return parts
        case .steps:
            return stepsParts(locale: locale)
        case .sleep:
            return sleepParts(locale: locale)
        case .weight:
            guard let weight else { return [] }
            // Like the tile: the weight only (#73); the trend is in the detail.
            return [String(localized: "\(decimal(weight.latestKg)) kilograms", locale: locale)]
                + [weeklyParts(weight.latestKg, average: weeklyWeightKg, locale: locale), measured(weight.latest.day)]
                .compactMap(\.self)
        case .bodyFat:
            guard let bodyFat else { return [] }
            return [String(localized: "\(decimal(bodyFat.pct)) percent", locale: locale)]
                + [weeklyParts(bodyFat.pct, average: weeklyBodyFatPct, locale: locale), measured(bodyFat.day)].compactMap(\.self)
        case .totalEnergy:
            guard let burned = energyBurned else { return [] }
            if let total = burned.totalKcal, let active = burned.activeKcal, let resting = burned.restingKcal {
                let totalValue = energy(total)
                let activeValue = energy(active)
                let restingValue = energy(resting)
                return [
                    isKcal
                        ? String(localized: "\(totalValue) calories", locale: locale)
                        : String(localized: "\(totalValue) kilojoules", locale: locale),
                    String(localized: "active \(activeValue)", locale: locale),
                    activeGoalPart(active, value: energy, locale: locale),
                    String(localized: "resting \(restingValue)", locale: locale),
                ]
            }
            // Only one part is known: say which, and that there is no total.
            let active = burned.activeKcal.map { kcal in
                let value = energy(kcal)
                return isKcal
                    ? String(localized: "active \(value) calories", locale: locale)
                    : String(localized: "active \(value) kilojoules", locale: locale)
            } ?? String(localized: "active energy unknown", locale: locale)
            let resting = burned.restingKcal.map { kcal in
                let value = energy(kcal)
                return isKcal
                    ? String(localized: "resting \(value) calories", locale: locale)
                    : String(localized: "resting \(value) kilojoules", locale: locale)
            } ?? String(localized: "resting energy unknown", locale: locale)
            return [active, burned.activeKcal.map { activeGoalPart($0, value: energy, locale: locale) }, resting,
                    String(localized: "no total yet", locale: locale)].compactMap(\.self)
        case .restingHeartRate, .hrv:
            guard let comparison = tile == .hrv ? hrv : restingHR else { return [] }
            let value = Self.count(comparison.value)
            let average = Self.count(comparison.average7)
            var parts = [
                tile == .hrv
                    ? String(localized: "\(value) milliseconds", locale: locale)
                    : String(localized: "\(value) beats per minute", locale: locale),
                String(localized: "7-day average \(average)", locale: locale),
            ]
            // The value's colour is read against the 30-day average (#74), so say where it stands.
            if let deviation = comparison.deviationText {
                parts.append(deviation)
            }
            parts += [measured(comparison.day)].compactMap(\.self)
            return parts
        case .caffeine, .water:
            return [] // spoken with the time, see accessibilityLabel
        case .weeklyReport:
            return [] // the report lives in the model, see `LastWeekTileText.spoken`
        }
    }

    /// "1,840 of 2,400 millilitres" and where the day stands, which is what the tile's colour shows.
    private func hydrationParts(_ day: HydrationDay, locale: Locale) -> [String] {
        func time(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        }
        let status = switch day.status {
        case .goalReached:
            String(localized: "goal reached", locale: locale)
        case .onPace:
            String(localized: "on pace", locale: locale)
        case let .behind(byMl):
            String(localized: "\(Self.count(byMl)) millilitres behind pace", locale: locale)
        case let .inGap(since):
            String(localized: "no drink since \(time(since))", locale: locale)
        }
        let total = Self.count(day.totalMl)
        let goal = Self.count(day.goalMl)
        return [String(localized: "\(total) of \(goal) millilitres", locale: locale), status]
    }

    /// "above the weekly average" — what the value's colour is read against; nil without a weekly average.
    private func weeklyParts(_ value: Double, average: Double?, locale: Locale) -> String? {
        guard let average else { return nil }
        let difference = ((value - average) * 10).rounded() / 10
        if difference == 0 {
            return String(localized: "at the weekly average", locale: locale)
        }
        return difference < 0
            ? String(localized: "below the weekly average", locale: locale)
            : String(localized: "above the weekly average", locale: locale)
    }

    /// "close to the active goal of 500" — what the active part's colour is read against.
    private func activeGoalPart(_ kcal: Double, value: (Double) -> Int, locale: Locale) -> String {
        let goal = value(Double(activeEnergyGoalKcal))
        return switch ActiveEnergyGoal.band(kcal: kcal, goal: activeEnergyGoalKcal) {
        case .reached: String(localized: "active goal of \(goal) reached", locale: locale)
        case .near: String(localized: "close to the active goal of \(goal)", locale: locale)
        case .far: String(localized: "below the active goal of \(goal)", locale: locale)
        }
    }

    /// "8,500 steps", "close to the goal of 10,000".
    private func stepsParts(locale: Locale) -> [String] {
        guard let steps else { return [] }
        let goal = switch StepGoal.band(steps: Double(steps), goal: stepGoal) {
        case .reached: String(localized: "goal of \(stepGoal) reached", locale: locale)
        case .near: String(localized: "close to the goal of \(stepGoal)", locale: locale)
        case .far: String(localized: "below the goal of \(stepGoal)", locale: locale)
        }
        return [String(localized: "\(steps) steps", locale: locale), goal]
    }

    /// Like the tile: time asleep only; time in bed when that is all Health has.
    private func sleepParts(locale: Locale) -> [String] {
        guard let minutes = sleepMinutes else { return [] }
        let goalText = Self.spokenDuration(sleepGoalMin, locale: locale)
        let goal = switch SleepGoal.band(minutes: Double(minutes), goal: sleepGoalMin) {
        case .reached: String(localized: "goal of \(goalText) reached", locale: locale)
        case .near: String(localized: "close to the goal of \(goalText)", locale: locale)
        case .far: String(localized: "below the goal of \(goalText)", locale: locale)
        }
        let duration = Self.spokenDuration(minutes, locale: locale)
        let value = sleep?.asleepMin == nil
            ? String(localized: "\(duration) in bed", locale: locale)
            : String(localized: "\(duration) asleep", locale: locale)
        return [value, goal]
    }

    /// The tile's 7-day trend for VoiceOver ("up over 7 days"), spoken as the tile's value; nil without a chart or
    /// when the tile shows no value.
    func accessibilityTrend(of tile: DashboardTile, state: TileState) -> String? {
        guard state == .ready else { return nil }
        return sparkline(for: tile)?.accessibilitySummary
    }

    /// "7 hours 5 minutes", "1 hour", "45 minutes": one phrase with integer counts, so the catalog holds the plural
    /// forms of both units.
    static func spokenDuration(_ minutes: Int, locale: Locale = .current) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 {
            return String(localized: "\(rest) minutes", locale: locale)
        }
        return rest == 0
            ? String(localized: "\(hours) hours", locale: locale)
            : String(localized: "\(hours) hours \(rest) minutes", locale: locale)
    }
}
