import Core
import DesignSystem
import SwiftUI

/// Where the Hydration tile's strip draws, as fractions of its width (0 at wake-up, 1 at bedtime): each drink in the
/// waking window as a bubble whose area follows the amount, the gaps without a drink, and now. Other apps' water has
/// no time, so it isn't drawn; drinks before wake-up or after bedtime count in the total only. Pure, so it is
/// unit-tested.
struct HydrationStripLayout: Equatable {
    struct Bubble: Equatable {
        var x: Double
        /// In points.
        var radius: Double
        var kind: FluidIntake.Kind
    }

    struct Span: Equatable {
        var start: Double
        var end: Double
    }

    /// Points per √ml, so a 500 ml glass has a radius of about 11 pt.
    static let radiusPerRootMl = 11 / 500.0.squareRoot()
    /// A sip stays visible.
    static let minRadius = 2.0
    /// A big bottle still fits the strip, which is `2 · maxRadius` high.
    static let maxRadius = 14.0

    let bubbles: [Bubble]
    let gaps: [Span]
    /// Nil before wake-up and after bedtime.
    let now: Double?

    init(day: HydrationDay) {
        let span = day.bedtime.timeIntervalSince(day.wake)
        guard span > 0 else {
            bubbles = []
            gaps = []
            now = nil
            return
        }
        func x(_ date: Date) -> Double {
            date.timeIntervalSince(day.wake) / span
        }
        let window = day.wake ... day.bedtime
        bubbles = day.intakes.filter { window.contains($0.at) }.map {
            Bubble(x: x($0.at), radius: Self.radius(ml: $0.ml), kind: $0.kind)
        }
        gaps = day.gaps.map { Span(start: x($0.start), end: x($0.end)) }
        now = window.contains(day.now) ? x(day.now) : nil
    }

    /// The bubble's area follows the amount: `√ml · radiusPerRootMl`, within `minRadius ... maxRadius`.
    static func radius(ml: Double) -> Double {
        min(max(max(ml, 0).squareRoot() * radiusPerRootMl, minRadius), maxRadius)
    }
}

/// Today's drinks from wake-up to bedtime (spec §3): a bubble per drink (plain water in the water colour, other
/// drinks orange), stretches without a drink tinted, a tick at now. One VoiceOver element, e.g. "8 drinks, longest
/// gap 4 h 30 min".
struct HydrationStrip: View {
    let day: HydrationDay

    var body: some View {
        let layout = HydrationStripLayout(day: day)
        Canvas { context, size in
            // Inset by the largest radius, so a drink at wake-up or bedtime isn't cut off.
            let inset = HydrationStripLayout.maxRadius
            let width = max(size.width - 2 * inset, 0)
            func x(_ fraction: Double) -> CGFloat {
                inset + width * fraction
            }
            let middle = size.height / 2

            for gap in layout.gaps {
                let rect = CGRect(x: x(gap.start), y: 0, width: x(gap.end) - x(gap.start), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(GoalColor.missed.opacity(0.12)))
            }

            var axis = Path()
            axis.move(to: CGPoint(x: x(0), y: middle))
            axis.addLine(to: CGPoint(x: x(1), y: middle))
            context.stroke(axis, with: .color(NL.Palette.track), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for bubble in layout.bubbles {
                let radius = bubble.radius
                let rect = CGRect(x: x(bubble.x) - radius, y: middle - radius, width: 2 * radius, height: 2 * radius)
                context.fill(Path(ellipseIn: rect), with: .color(Self.color(bubble.kind).opacity(0.85)))
            }

            if let now = layout.now {
                var tick = Path()
                tick.move(to: CGPoint(x: x(now), y: 0))
                tick.addLine(to: CGPoint(x: x(now), y: size.height))
                context.stroke(tick, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(height: 2 * HydrationStripLayout.maxRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(day))
        .allowsHitTesting(false)
    }

    private static func color(_ kind: FluidIntake.Kind) -> Color {
        switch kind {
        case .water: NL.Palette.water
        case .other: .orange
        }
    }

    /// "8 drinks, longest gap 4 h 30 min", "1 drink", "No drinks yet"; the gap only when there is one.
    nonisolated static func accessibilityLabel(_ day: HydrationDay) -> String {
        let count = day.intakes.count
        guard let longest = day.gaps.map({ $0.end.timeIntervalSince($0.start) }).max() else {
            return count == 0 ? String(localized: "No drinks yet") : String(localized: "\(count) drinks")
        }
        let gap = Format.duration(minutes: Int(longest / 60))
        return count == 0
            ? String(localized: "No drinks yet, longest gap \(gap)")
            : String(localized: "\(count) drinks, longest gap \(gap)")
    }
}
