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

        var id: Int {
            index
        }
    }

    static let days = 7

    let mark: Mark
    /// Days with a value, oldest first. Days without one are gaps (no zero is invented).
    let points: [Point]

    /// - Parameter values: the metric per day; only the `days` days ending `today` are used.
    init(_ values: [LocalDay: Double], today: LocalDay, mark: Mark) {
        self.mark = mark
        points = (0 ..< Self.days).compactMap { index in
            let day = today.adding(days: index - (Self.days - 1))
            guard let value = values[day], value.isFinite else { return nil }
            return Point(day: day, index: index, value: value)
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
    /// The 7-day series of every tile that has one. The calories tile has none: its ring is about today.
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

        // Water: logged in Nutrilog plus other apps' water from Health, as on the tile; a day with neither is a gap.
        var water: [LocalDay: Double] = data.waterByDay
        for row in recent {
            if let other = row.waterMl {
                water[row.day, default: 0] += other
            }
        }
        water = water.filter { $0.value > 0 }

        let steps = series { $0.steps.map(Double.init) }
        let total = series { EnergyBurned(activeKcal: $0.activeKcal, restingKcal: $0.basalKcal).totalKcal }
        let sleepHours = series { ($0.sleepAsleepMin ?? $0.sleepInBedMin).map { Double($0) / 60 } }
        return [
            .steps: Sparkline(steps, today: today, mark: .bar),
            .activeEnergy: Sparkline(series(\.activeKcal), today: today, mark: .bar),
            .totalEnergy: Sparkline(total, today: today, mark: .bar),
            .sleep: Sparkline(sleepHours, today: today, mark: .bar),
            .water: Sparkline(water, today: today, mark: .bar),
            .weight: Sparkline(WeightTrend.trendByDay(weightByDay, through: today), today: today, mark: .line),
            .bodyFat: Sparkline(bodyFatByDay, today: today, mark: .line),
            .restingHeartRate: Sparkline(series(\.restingHR), today: today, mark: .line),
            .hrv: Sparkline(series(\.hrvSDNNms), today: today, mark: .line),
        ]
    }
}

// MARK: - View

/// The tile's sparkline: no axes, no interaction, hidden from VoiceOver (the tile speaks the trend instead).
struct SparklineView: View {
    let sparkline: Sparkline
    var tint: Color = NL.Palette.trend

    private static let categories = (0 ..< Sparkline.days).map(String.init)

    var body: some View {
        Chart(sparkline.points) { point in
            if sparkline.mark == .bar {
                BarMark(x: .value("Day", String(point.index)), y: .value("Value", point.value), width: .fixed(10))
                    .foregroundStyle(tint.opacity(point.index == Sparkline.days - 1 ? 1 : 0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
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
