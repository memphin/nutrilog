import Charts
import Core
import DesignSystem
import SwiftUI

/// The caffeine tile: the amount in the body now (coloured by `CaffeineLevel`), when it is sleep-safe, today's
/// total against the daily limit, the day's curve and the quick-add drinks.
struct CaffeineTileContent: View {
    let status: CaffeineStatus
    let drinks: [CaffeineDrink]
    let add: (CaffeineDrink) -> Void

    var body: some View {
        let color = GoalColor.color(status.band)
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.xs) {
                    Text(CaffeineStatus.mgNumber(status.mgNow))
                        .font(NL.Typography.number).monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(color)
                    Text("mg now").font(.footnote).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Spacer()
                Text(status.todayText)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(status.isOverDailyLimit ? GoalColor.missed : .secondary)
            }
            Label(status.outlookText(), systemImage: "moon.zzz")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CaffeineMiniChart(status: status, color: color)
            CaffeineQuickAddButtons(drinks: drinks, add: add)
        }
    }
}

/// The day's curve on the tile, morning to bedtime: no axes, the dashed sleep-safe line and a dot at now.
private struct CaffeineMiniChart: View {
    let status: CaffeineStatus
    let color: Color

    var body: some View {
        let window = status.tileWindow
        let points = status.curve(in: window, step: 600)
        let top = max(points.map(\.mg).max() ?? 0, status.thresholdMg * 1.5)
        Chart {
            ForEach(points, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                    .foregroundStyle(LinearGradient(
                        colors: [NL.Palette.caffeine.opacity(0.3), NL.Palette.caffeine.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom,
                    ))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Caffeine", point.mg))
                    .foregroundStyle(NL.Palette.caffeine)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            RuleMark(y: .value("Sleep-safe", status.thresholdMg))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(x: .value("Time", status.now), y: .value("Caffeine", status.mgNow))
                .foregroundStyle(color)
                .symbolSize(36)
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0 ... top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 44)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// "+ Espresso" buttons: one row when they fit, else two per row.
struct CaffeineQuickAddButtons: View {
    let drinks: [CaffeineDrink]
    let add: (CaffeineDrink) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NL.Spacing.s) {
                ForEach(drinks) { button($0, fill: false) }
            }
            VStack(alignment: .leading, spacing: NL.Spacing.s) {
                ForEach(Array(stride(from: 0, to: drinks.count, by: 2)), id: \.self) { start in
                    HStack(spacing: NL.Spacing.s) {
                        ForEach(drinks[start ..< min(start + 2, drinks.count)]) { button($0, fill: true) }
                    }
                }
            }
        }
    }

    private func button(_ drink: CaffeineDrink, fill: Bool) -> some View {
        Button {
            add(drink)
        } label: {
            Label(drink.name, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: fill ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .tint(NL.Palette.caffeine)
        .accessibilityLabel("Add \(drink.name), \(CaffeineStatus.mgNumber(drink.mg)) milligrams of caffeine")
    }
}
