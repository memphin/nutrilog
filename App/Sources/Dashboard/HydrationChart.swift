import Charts
import Core
import DesignSystem
import SwiftUI

/// The Hydration detail's chart (spec §3): the running total of today's timed drinks as a step line, the dashed pace
/// line from wake-up to an hour before bedtime, the goal, a point per drink (water in the water colour, other drinks
/// orange), the gaps without a drink tinted, and now. Other apps' water has no time, so it isn't drawn.
struct HydrationChart: View {
    let day: HydrationDay

    struct Step: Identifiable {
        var at: Date
        var totalMl: Double
        var id: Date {
            at
        }
    }

    var body: some View {
        let window = Self.window(day)
        let points = Self.points(day, window: window)
        let top = max(day.goalMl, day.steps.last?.totalMl ?? 0) * 1.1
        Chart {
            ForEach(day.gaps, id: \.start) { gap in
                RectangleMark(
                    xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end),
                    yStart: .value("Bottom", 0), yEnd: .value("Top", top),
                )
                .foregroundStyle(GoalColor.missed.opacity(0.12))
            }
            if day.isWindowValid {
                ForEach([(day.wake, 0.0), (day.paceEnd, day.goalMl)], id: \.0) { date, ml in
                    LineMark(x: .value("Time", date), y: .value("Pace", ml), series: .value("Line", "Pace"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            RuleMark(y: .value("Goal", day.goalMl))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(Self.totalLine(day, window: window)) { step in
                LineMark(x: .value("Time", step.at), y: .value("Total", step.totalMl), series: .value("Line", "Total"))
                    .foregroundStyle(NL.Palette.water)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(points, id: \.intake.id) { point in
                PointMark(x: .value("Time", point.at), y: .value("Total", point.totalMl))
                    .foregroundStyle(Self.color(point.intake.kind))
                    .symbolSize(40)
            }
            if window.contains(day.now) {
                RuleMark(x: .value("Now", day.now))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0 ... top)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ml = value.as(Double.self) {
                        Text(ml.formatted(.number.precision(.fractionLength(0))))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hydration chart")
        .accessibilityValue(Self.accessibilityValue(day))
    }

    /// The day the chart spans: wake-up to bedtime, so a drink at an odd time doesn't squash it (such drinks are
    /// drawn at its edges). Without a valid waking window, everything from the earliest to the latest of wake-up,
    /// bedtime, now and the drinks.
    static func window(_ day: HydrationDay) -> ClosedRange<Date> {
        if day.isWindowValid {
            return day.wake ... day.bedtime
        }
        let dates = [day.wake, day.bedtime, day.now] + day.intakes.map(\.at)
        let start = dates.min() ?? day.wake
        let end = dates.max() ?? day.bedtime
        return start ... max(end, start.addingTimeInterval(3600))
    }

    /// The running total from the window's start (0, or what was drunk before it) through each drink to now (or the
    /// last drink, when later); drinks outside the window count at its edges.
    static func totalLine(_ day: HydrationDay, window: ClosedRange<Date>) -> [Step] {
        var line = [Step(at: window.lowerBound, totalMl: 0)]
            + day.steps.map { Step(at: $0.at.clamped(to: window), totalMl: $0.totalMl) }
        let last = line[line.count - 1]
        let end = max(min(day.now, window.upperBound), last.at)
        if end > last.at {
            line.append(Step(at: end, totalMl: last.totalMl))
        }
        // Drinks at the same moment (also at the window's start) are one step: ids must be unique.
        var unique: [Step] = []
        for step in line {
            if unique.last?.at == step.at {
                unique[unique.count - 1] = step
            } else {
                unique.append(step)
            }
        }
        return unique
    }

    /// Each drink where it is drawn (outside the window: at its edge), with the running total after it.
    static func points(_ day: HydrationDay, window: ClosedRange<Date>) -> [(intake: FluidIntake, at: Date, totalMl: Double)] {
        zip(day.intakes, day.steps).map { intake, step in (intake: intake, at: intake.at.clamped(to: window), totalMl: step.totalMl) }
    }

    private static func color(_ kind: FluidIntake.Kind) -> Color {
        switch kind {
        case .water: NL.Palette.water
        case .other: .orange
        }
    }

    /// "1,200 ml of 2,400 so far, the pace line is at 1,400 now."
    private static func accessibilityValue(_ day: HydrationDay) -> String {
        /// Whole millilitres as integers, so the catalog can pick the plural form.
        func whole(_ value: Double) -> Int {
            Int(value.rounded(.toNearestOrEven))
        }
        let timed = whole(day.steps.last?.totalMl ?? 0)
        let goal = whole(day.goalMl)
        var parts = [String(localized: "\(timed) of \(goal) millilitres with a time so far")]
        if let pace = day.pace(at: day.now).map(whole) {
            parts.append(String(localized: "the pace line is at \(pace) now"))
        }
        if !day.gaps.isEmpty {
            parts.append(HydrationStrip.accessibilityLabel(day))
        }
        return parts.joined(separator: ", ") + "."
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
