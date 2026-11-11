import SwiftUI
import WidgetKit

// Home Screen and Lock Screen widgets (FR-70, backlog #42). They show the snapshot of today that the app writes to
// the shared App Group container after every change (`WidgetSnapshot`), and never open the database.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Today's numbers; nil before the app was opened for the first time.
    let snapshot: WidgetSnapshot?

    /// The snapshot as it should be shown on `date`: a snapshot of an earlier day becomes an empty day that keeps
    /// the targets (nothing is logged yet today), instead of yesterday's numbers. The app stores Gregorian days, so
    /// the day is built with a Gregorian calendar in `calendar`'s time zone (a Buddhist-calendar device would
    /// otherwise yield year 2569 and never match).
    static func current(_ snapshot: WidgetSnapshot?, on date: Date, calendar: Calendar = .current) -> WidgetSnapshot? {
        guard var snapshot else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard snapshot.day != today else { return snapshot }
        snapshot.day = today
        snapshot.kcal = 0
        snapshot.proteinG = 0
        snapshot.carbsG = 0
        snapshot.fatG = 0
        snapshot.waterMl = 0
        snapshot.steps = nil
        snapshot.sleepMin = nil
        return snapshot
    }

    static let placeholder = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(
        day: "", kcal: 1380, targetKcal: 2200, proteinG: 96, carbsG: 150, fatG: 44,
        targetProteinG: 160, targetCarbsG: 220, targetFatG: 75, steps: 6420, sleepMin: 432, weightKg: 81.6,
        waterMl: 1250, waterGoalMl: 2500, energyUnit: "kcal", updatedAt: Date(),
    ))
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in _: Context) -> SnapshotEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry(at: Date()))
    }

    /// Now, and again just after midnight (a new, empty day). The app reloads the timeline whenever the data changes.
    func getTimeline(in _: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry(at: now), entry(at: midnight)], policy: .after(midnight.addingTimeInterval(60))))
    }

    private func entry(at date: Date) -> SnapshotEntry {
        SnapshotEntry(date: date, snapshot: SnapshotEntry.current(WidgetSnapshot.load(), on: date))
    }
}

// MARK: - Formatting

/// `value` rounded to a whole number for display, without trapping: non-finite → 0, beyond `Int` → clamped. The
/// widget extension doesn't link Core, so this mirrors `DisplayRounding.whole`.
private func wholeNumber(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    let rounded = value.rounded()
    // Double(Int.max) rounds up to 2^63, which doesn't fit in Int, so compare with >= / <=.
    if rounded >= Double(Int.max) {
        return Int.max
    }
    if rounded <= Double(Int.min) {
        return Int.min
    }
    return Int(rounded)
}

extension WidgetSnapshot {
    static let kJPerKcal = 4.184

    private var factor: Double {
        energyUnit == "kJ" ? Self.kJPerKcal : 1
    }

    var remainingKcal: Double? {
        targetKcal.map { $0 - kcal }
    }

    /// 0…1 of the target eaten; 0 without a target.
    var energyFraction: Double {
        guard let targetKcal, targetKcal > 0 else { return 0 }
        return min(max(kcal / targetKcal, 0), 1)
    }

    var isOverTarget: Bool {
        (remainingKcal ?? 0) < 0
    }

    func energy(_ kcal: Double) -> String {
        (kcal * factor).formatted(.number.precision(.fractionLength(0)))
    }

    /// "640 kcal left", "120 kcal over", "1,380 kcal" without a target.
    var energyStatus: String {
        guard let remainingKcal else { return "\(energy(kcal)) \(energyUnit)" }
        return remainingKcal >= 0 ? "\(energy(remainingKcal)) \(energyUnit) left" : "\(energy(-remainingKcal)) \(energyUnit) over"
    }

    var sleepText: String? {
        sleepMin.map { "\($0 / 60) h \(String(format: "%02d", $0 % 60))" }
    }
}

// MARK: - Views

struct EnergyRingView: View {
    let snapshot: WidgetSnapshot
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: snapshot.energyFraction)
                .stroke(snapshot.isOverTarget ? Color.red : Color.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "fork.knife")
            Text("Open Vitalion").font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

struct CaloriesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: snapshot.energyFraction) {
                    Image(systemName: "flame")
                } currentValueLabel: {
                    Text(snapshot.energy(abs(snapshot.remainingKcal ?? snapshot.kcal)))
                }
                .gaugeStyle(.accessoryCircular)
                .accessibilityLabel("Calories")
                .accessibilityValue(snapshot.energyStatus)
            case .accessoryInline:
                Label(snapshot.energyStatus, systemImage: "flame")
            default:
                ZStack {
                    EnergyRingView(snapshot: snapshot)
                    VStack(spacing: 0) {
                        Text(snapshot.energy(abs(snapshot.remainingKcal ?? snapshot.kcal)))
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .minimumScaleFactor(0.6)
                        Text(snapshot.remainingKcal == nil ? snapshot.energyUnit : snapshot.isOverTarget ? "\(snapshot.energyUnit) over" : "\(snapshot.energyUnit) left")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue(snapshot.energyStatus)
            }
        } else {
            EmptyWidgetView()
        }
    }
}

struct MacroBarView: View {
    let title: String
    let value: Double
    let target: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(target.map { "\(wholeNumber(value)) / \(wholeNumber($0)) g" } ?? "\(wholeNumber(value)) g")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(target.map { "\(wholeNumber(value)) of \(wholeNumber($0)) grams" } ?? "\(wholeNumber(value)) grams")
    }

    private var fraction: Double {
        guard let target, target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }
}

struct MacrosWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 16) {
                ZStack {
                    EnergyRingView(snapshot: snapshot, lineWidth: 9)
                    VStack(spacing: 0) {
                        Text(snapshot.energy(abs(snapshot.remainingKcal ?? snapshot.kcal)))
                            .font(.system(.title3, design: .rounded).weight(.bold)).minimumScaleFactor(0.6)
                        Text(snapshot.remainingKcal == nil ? snapshot.energyUnit : snapshot.isOverTarget ? "over" : "left")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                .frame(maxWidth: 110)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue(snapshot.energyStatus)
                VStack(spacing: 8) {
                    MacroBarView(title: "Protein", value: snapshot.proteinG, target: snapshot.targetProteinG, color: .teal)
                    MacroBarView(title: "Carbs", value: snapshot.carbsG, target: snapshot.targetCarbsG, color: .orange)
                    MacroBarView(title: "Fat", value: snapshot.fatG, target: snapshot.targetFatG, color: .pink)
                }
            }
        } else {
            EmptyWidgetView()
        }
    }
}

struct MetricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Label(snapshot.energyStatus, systemImage: "flame").font(.headline)
                    Text([
                        snapshot.steps.map { "\($0.formatted()) steps" },
                        snapshot.weightKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" },
                    ].compactMap(\.self).joined(separator: " · "))
                    Text("Water \(wholeNumber(snapshot.waterMl)) / \(wholeNumber(snapshot.waterGoalMl)) ml")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        metric("flame", "Calories", snapshot.energyStatus)
                        metric("figure.walk", "Steps", snapshot.steps.map { $0.formatted() } ?? "—")
                    }
                    GridRow {
                        metric("bed.double", "Sleep", snapshot.sleepText ?? "—")
                        metric("scalemass", "Weight", snapshot.weightKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "—")
                    }
                    GridRow {
                        metric("drop", "Water", "\(wholeNumber(snapshot.waterMl)) / \(wholeNumber(snapshot.waterGoalMl)) ml")
                            .gridCellColumns(2)
                    }
                }
            }
        } else {
            EmptyWidgetView()
        }
    }

    private func metric(_ image: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: image).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.system(.footnote, design: .rounded).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widgets

struct CaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CaloriesRemaining", provider: SnapshotProvider()) { entry in
            CaloriesWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Calories left")
        .description("How much of today's calorie target is left.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct MacrosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Macros", provider: SnapshotProvider()) { entry in
            MacrosWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Calories & macros")
        .description("Calories left and today's protein, carbs and fat against your targets.")
        .supportedFamilies([.systemMedium])
    }
}

struct MetricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayMetrics", provider: SnapshotProvider()) { entry in
            MetricsWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Calories, steps, sleep, weight and water for today.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

@main
struct VitalionWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaloriesWidget()
        MacrosWidget()
        MetricsWidget()
    }
}
