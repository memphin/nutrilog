import Charts
import Core
import DesignSystem
import Foundation
import SwiftUI

/// The last 7 days of one tile's metric, drawn as a small non-interactive chart on the tile (owner feedback;
/// the full charts with ranges and scrubbing are #38). Pure, so the series rules are unit-tested.
struct Sparkline: Equatable {
    enum Mark: Equatable {
        /// Daily amounts that start at zero: steps, energy, sleep, water.
        case bar
        /// Levels where the change matters, not the amount: weight trend, body fat, heart rate, HRV.
        case line

        /// A 7-day change below this share of the average reads as "steady": daily amounts swing a lot, levels
        /// little (half a percent of body weight in a week is a real trend).
        var steadyThreshold: Double {
            switch self {
            case .bar: 0.05
            case .line: 0.005
            }
        }
    }

    enum Direction: Equatable {
        case up, down, steady
    }

    struct Point: Equatable, Identifiable {
        var day: LocalDay
        /// 0 for the window's first day … `days - 1` for today.
        var index: Int
        var value: Double
        /// The lower part of a stacked bar (Total energy: resting; the rest of `value` is active). nil: one bar.
        var base: Double?

        var id: Int {
            index
        }
    }

    static let days = 7

    let mark: Mark
    /// Days with a value, oldest first. Days without one are gaps (no zero is invented).
    let points: [Point]

    /// - Parameters:
    ///   - values: the metric per day; only the `days` days ending `today` are used.
    ///   - bases: the lower part of each day's stacked bar, where there is one.
    init(_ values: [LocalDay: Double], today: LocalDay, mark: Mark, bases: [LocalDay: Double] = [:]) {
        self.mark = mark
        points = (0 ..< Self.days).compactMap { index in
            let day = today.adding(days: index - (Self.days - 1))
            guard let value = values[day], value.isFinite else { return nil }
            return Point(day: day, index: index, value: value, base: bases[day].map { min(max($0, 0), value) })
        }
    }

    /// Two values make a shape; with fewer the tile shows no chart.
    var isDrawable: Bool {
        points.count >= 2
    }

    /// The points the trend is read from. Bars are daily amounts and today's is still growing (it would read as
    /// "down" every morning), so they use complete days only; levels (lines) include today.
    var trendPoints: [Point] {
        mark == .bar ? points.filter { $0.index < Self.days - 1 } : points
    }

    /// The least-squares slope over the window compared with the average: robust to one odd day and to gaps.
    var direction: Direction? {
        let points = trendPoints
        guard isDrawable, points.count >= 2 else { return nil }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + Double($1.index) } / count
        let meanY = points.reduce(0) { $0 + $1.value } / count
        let sxx = points.reduce(0) { $0 + (Double($1.index) - meanX) * (Double($1.index) - meanX) }
        let sxy = points.reduce(0) { $0 + (Double($1.index) - meanX) * ($1.value - meanY) }
        guard sxx > 0 else { return .steady }
        let change = sxy / sxx * Double(Self.days - 1)
        let scale = abs(meanY)
        if scale == 0 {
            return change == 0 ? .steady : change > 0 ? .up : .down
        }
        if abs(change) / scale < mark.steadyThreshold {
            return .steady
        }
        return change > 0 ? .up : .down
    }

    /// Spoken after the tile's value, e.g. "up over 7 days"; nil without a chart.
    var accessibilitySummary: String? {
        switch direction {
        case .up: "up over \(Self.days) days"
        case .down: "down over \(Self.days) days"
        case .steady: "steady over \(Self.days) days"
        case nil: nil
        }
    }
}

// MARK: - Series per tile

extension DashboardSnapshot {
    /// The 7-day series of every tile that has one. The calories tile has none (its ring is about today).
    static func sparklines(
        data: DashboardData,
        rows: [DailyHealthMetrics],
        dayWeights: [DayWeight],
    ) -> [DashboardTile: Sparkline] {
        let today = data.today
        let first = today.adding(days: -(Sparkline.days - 1))
        let recent = rows.filter { $0.day >= first && $0.day <= today }
        func series(_ value: (DailyHealthMetrics) -> Double?) -> [LocalDay: Double] {
            var result: [LocalDay: Double] = [:]
            for row in recent {
                if let value = value(row) {
                    result[row.day] = value
                }
            }
            return result
        }

        var weightByDay: [LocalDay: Double] = [:]
        var bodyFatByDay: [LocalDay: Double] = [:]
        for weight in dayWeights where weight.day <= today {
            weightByDay[weight.day] = weight.kg
            bodyFatByDay[weight.day] = weight.bodyFatPct
        }

        // Water: logged in Vitalion plus other apps' water from Health, as on the tile; a day with neither is a gap.
        var water: [LocalDay: Double] = data.waterByDay
        for row in recent {
            if let other = row.waterMl {
                water[row.day, default: 0] += other
            }
        }
        water = water.filter { $0.value > 0 }

        let steps = series { $0.steps.map(Double.init) }
        let total = series { EnergyBurned(activeKcal: $0.activeKcal, restingKcal: $0.basalKcal).totalKcal }
        // Each total is drawn as resting + active (#66).
        let resting = series { EnergyBurned(activeKcal: $0.activeKcal, restingKcal: $0.basalKcal).totalKcal == nil ? nil : $0.basalKcal }
        // Like the tile's value: time asleep, or time in bed when that is all Health has (#72).
        let sleep = series { ($0.sleepAsleepMin ?? $0.sleepInBedMin).map(Double.init) }
        return [
            .steps: Sparkline(steps, today: today, mark: .bar),
            .sleep: Sparkline(sleep, today: today, mark: .bar),
            .totalEnergy: Sparkline(total, today: today, mark: .bar, bases: resting),
            .water: Sparkline(water, today: today, mark: .bar),
            .weight: Sparkline(WeightTrend.trendByDay(weightByDay, through: today), today: today, mark: .line),
            .bodyFat: Sparkline(bodyFatByDay, today: today, mark: .line),
            .restingHeartRate: Sparkline(series(\.restingHR), today: today, mark: .line),
            .hrv: Sparkline(series(\.hrvSDNNms), today: today, mark: .line),
        ]
    }
}

// MARK: - Goal colours

/// The colours of values measured against a daily goal or a baseline (#63, #64, #72, #74).
enum GoalColor {
    static let reached = Color.green
    static let near = Color.orange
    static let missed = Color.red

    static func color(_ band: GoalBand) -> Color {
        switch band {
        case .reached: reached
        case .near: near
        case .far: missed
        }
    }

    /// Steps: green at or above the goal, orange close below it, red far below.
    static func steps(_ steps: Double, goal: Int) -> Color {
        color(StepGoal.band(steps: steps, goal: goal))
    }

    /// Sleep: green at or above the goal, orange up to an hour short, red further below.
    static func sleep(minutes: Double, goal: Int) -> Color {
        color(SleepGoal.band(minutes: minutes, goal: goal))
    }

    /// Water: green at or above the goal, orange close below it, red far below.
    static func water(_ ml: Double, goalMl: Double) -> Color {
        color(WaterGoal.band(ml: ml, goalMl: goalMl))
    }
}

extension DashboardSnapshot {
    /// The colour of one day's bar on a tile's sparkline; nil for tiles without a goal (the tile's tint is used).
    func goalColor(of tile: DashboardTile, value: Double) -> Color? {
        switch tile {
        case .steps: GoalColor.steps(value, goal: stepGoal)
        case .sleep: GoalColor.sleep(minutes: value, goal: sleepGoalMin)
        case .water: GoalColor.water(value, goalMl: water.goalMl)
        default: nil
        }
    }

    /// How the latest weight (by the profile's goal) or body fat compares with the week before; nil without a
    /// weekly average, or for weight when the goal is to maintain.
    func weeklyBand(of tile: DashboardTile) -> GoalBand? {
        switch tile {
        case .weight:
            guard let weight, let weeklyWeightKg else { return nil }
            return WeeklyBand.weight(kg: weight.latestKg, average: weeklyWeightKg, goal: goalMode)
        case .bodyFat:
            guard let bodyFat, let weeklyBodyFatPct else { return nil }
            return WeeklyBand.bodyFat(pct: bodyFat.pct, average: weeklyBodyFatPct)
        default:
            return nil
        }
    }

    /// The colour of a value read against a baseline: HRV and resting heart rate against the 30-day average (#74),
    /// weight and body fat against the week before; nil without the baseline.
    func baselineColor(of tile: DashboardTile) -> Color? {
        switch tile {
        case .weight, .bodyFat: weeklyBand(of: tile).map(GoalColor.color)
        case .hrv: hrv.flatMap(BaselineBand.hrv).map(GoalColor.color)
        case .restingHeartRate: restingHR.flatMap(BaselineBand.restingHR).map(GoalColor.color)
        default: nil
        }
    }
}

// MARK: - View

/// The tile's sparkline: no axes, no interaction, hidden from VoiceOver (the tile speaks the trend instead).
struct SparklineView: View {
    let sparkline: Sparkline
    var tint: Color = NL.Palette.trend
    /// A bar's own colour (goal colours); nil uses `tint`, dimmed for past days.
    var color: (Sparkline.Point) -> Color? = { _ in nil }

    private static let categories = (0 ..< Sparkline.days).map(String.init)

    var body: some View {
        Chart(sparkline.points) { point in
            if sparkline.mark == .bar {
                let x = PlottableValue.value("Day", String(point.index))
                let isToday = point.index == Sparkline.days - 1
                if let base = point.base {
                    // Stacked: the lower part lighter, the upper part full.
                    BarMark(x: x, y: .value("Value", base), width: .fixed(10))
                        .foregroundStyle(tint.opacity(isToday ? 0.5 : 0.25))
                    BarMark(x: x, y: .value("Value", point.value - base), width: .fixed(10))
                        .foregroundStyle(tint.opacity(isToday ? 1 : 0.6))
                } else {
                    BarMark(x: x, y: .value("Value", point.value), width: .fixed(10))
                        .foregroundStyle((color(point) ?? tint).opacity(isToday ? 1 : color(point) == nil ? 0.45 : 0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else {
                LineMark(x: .value("Day", String(point.index)), y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Day", String(point.index)), y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .symbolSize(point.id == sparkline.points.last?.id ? 24 : 0)
            }
        }
        .chartXScale(domain: Self.categories)
        .chartYScale(domain: .automatic(includesZero: sparkline.mark == .bar))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 28)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
