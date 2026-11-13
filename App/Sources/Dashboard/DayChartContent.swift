import Charts
import Core
import DesignSystem
import SwiftUI

// Pieces shared by the day charts of the caffeine tile and detail and the hydration detail.

/// The caffeine curve: a soft area under a smooth line.
struct CaffeineCurveMarks: ChartContent {
    let points: [CaffeinePoint]
    /// The area's opacity at the top; it fades out towards zero.
    var areaOpacity = 0.35
    var lineWidth: CGFloat = 2.5

    var body: some ChartContent {
        ForEach(points, id: \.date) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                .foregroundStyle(LinearGradient(
                    colors: [NL.Palette.caffeine.opacity(areaOpacity), NL.Palette.caffeine.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom,
                ))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                .foregroundStyle(NL.Palette.caffeine)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A thin vertical line at the current time, labelled "Now".
struct NowRuleMark: ChartContent {
    let now: Date

    var body: some ChartContent {
        RuleMark(x: .value("Now", now))
            .foregroundStyle(Color.primary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
    }
}

extension View {
    /// The day charts' axes: hours every 3 hours along the bottom, `label` of the values on the left.
    func dayChartAxes(label: @escaping (Double) -> String) -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(label(number))
                    }
                }
            }
        }
    }
}
