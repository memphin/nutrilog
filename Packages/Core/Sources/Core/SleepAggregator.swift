import Foundation

/// One night of sleep from a single source (SPEC §3.4 sleep rules, backlog #25).
public struct SleepSummary: Hashable, Sendable, Codable {
    /// The day the night ends on: the night of D runs from 18:00 on D-1 to 18:00 on D.
    public var night: LocalDay
    /// The only source counted for this night.
    public var source: HealthSource
    /// Time asleep (core + deep + REM + unspecified). Nil when the source recorded no asleep samples at all,
    /// e.g. an iPhone that only estimates time in bed.
    public var asleep: TimeInterval?
    /// Time in bed: every moment covered by any sample of the source (asleep, awake or in bed).
    public var inBed: TimeInterval
    public var core: TimeInterval
    public var deep: TimeInterval
    public var rem: TimeInterval
    public var awake: TimeInterval
    /// Asleep without a stage (older watchOS, third-party apps).
    public var unspecified: TimeInterval
    /// When the user woke up: the end of the last asleep sample ending by noon on the night's day. Nil when the
    /// source recorded no asleep samples before noon. Afternoon naps do not move it.
    public var wokeAt: Date?

    public init(
        night: LocalDay, source: HealthSource, asleep: TimeInterval?, inBed: TimeInterval,
        core: TimeInterval = 0, deep: TimeInterval = 0, rem: TimeInterval = 0, awake: TimeInterval = 0,
        unspecified: TimeInterval = 0, wokeAt: Date? = nil,
    ) {
        self.night = night
        self.source = source
        self.asleep = asleep
        self.inBed = inBed
        self.core = core
        self.deep = deep
        self.rem = rem
        self.awake = awake
        self.unspecified = unspecified
        self.wokeAt = wokeAt
    }

    /// True when the source reports stages (Apple Watch with watchOS 9+).
    public var hasStages: Bool {
        core > 0 || deep > 0 || rem > 0
    }
}

/// Turns raw `sleepAnalysis` samples into one summary per night.
///
/// Rules (SPEC §3.4, D5):
/// - The night of day D is the window (18:00 D-1, 18:00 D]. A sample belongs to the night its *end* falls in, so
///   every sample counts for exactly one night; naps ending before 18:00 count toward that day.
/// - Exactly one source is counted per night, so samples from several sources can never be added together.
///   Apple Watch wins over other apps, which win over iPhone in-bed estimates (`HealthSourceKind`). Between
///   sources of the same kind, the one with the most time asleep wins.
/// - Within that source, overlapping samples are merged: every moment counts once. Where stages overlap, the
///   moment goes to the deepest stage: deep > REM > core > unspecified > awake > in bed for Apple Watch. Other
///   sources often write one long "asleep" block with awake periods inside it, so for them awake wins over
///   unspecified asleep (deep > REM > core > awake > unspecified > in bed).
public enum SleepAggregator {
    /// Hour of the day at which one night ends and the next begins.
    public static let nightBoundaryHour = 18

    /// The window (18:00 D-1, 18:00 D] for the night ending on `night`, in `calendar`'s time zone. It is 23 or
    /// 25 hours long when a DST change falls inside it.
    public static func nightWindow(for night: LocalDay, calendar: Calendar = .current) -> DateInterval {
        DateInterval(
            start: night.previous.date(atHour: nightBoundaryHour, calendar: calendar),
            end: night.date(atHour: nightBoundaryHour, calendar: calendar),
        )
    }

    /// The night a sample ending at `end` belongs to.
    public static func night(endingAt end: Date, calendar: Calendar = .current) -> LocalDay {
        let day = LocalDay(end, calendar: calendar)
        return end <= day.date(atHour: nightBoundaryHour, calendar: calendar) ? day : day.next
    }

    /// Summarizes the night ending on `night`, or returns nil when no sample ends inside its window.
    public static func aggregate(samples: [SleepSample], for night: LocalDay, calendar: Calendar = .current) -> SleepSummary? {
        let window = nightWindow(for: night, calendar: calendar)
        let inWindow = samples.filter { $0.end > $0.start && $0.end > window.start && $0.end <= window.end }
        guard !inWindow.isEmpty else { return nil }

        let candidates = Dictionary(grouping: inWindow, by: \.source.bundleIdentifier).values.map { group in
            measure(group, night: night, calendar: calendar)
        }
        return candidates.min { lhs, rhs in
            if lhs.source.kind != rhs.source.kind {
                return lhs.source.kind < rhs.source.kind
            }
            if (lhs.asleep ?? 0) != (rhs.asleep ?? 0) {
                return (lhs.asleep ?? 0) > (rhs.asleep ?? 0)
            }
            if lhs.inBed != rhs.inBed {
                return lhs.inBed > rhs.inBed
            }
            return lhs.source.bundleIdentifier < rhs.source.bundleIdentifier
        }
    }

    /// Summaries for every night in `nights` that has data.
    public static func aggregate(
        samples: [SleepSample],
        nights: ClosedRange<LocalDay>,
        calendar: Calendar = .current,
    ) -> [LocalDay: SleepSummary] {
        let byNight = Dictionary(grouping: samples) { night(endingAt: $0.end, calendar: calendar) }
        var result: [LocalDay: SleepSummary] = [:]
        for (night, group) in byNight where nights.contains(night) {
            result[night] = aggregate(samples: group, for: night, calendar: calendar)
        }
        return result
    }

    /// Stage precedence where samples of one Apple Watch overlap: the first stage covering a moment wins.
    static let watchPrecedence: [SleepStage] = [.asleepDeep, .asleepREM, .asleepCore, .asleepUnspecified, .awake, .inBed]
    /// Stage precedence for other sources: awake periods cut into an unspecified "asleep" block.
    static let fallbackPrecedence: [SleepStage] = [.asleepDeep, .asleepREM, .asleepCore, .awake, .asleepUnspecified, .inBed]

    /// Sweeps over the samples of one source, assigning every covered moment to exactly one stage.
    private static func measure(_ samples: [SleepSample], night: LocalDay, calendar: Calendar) -> SleepSummary {
        // The earliest sample names the source; all samples of the group share its bundle identifier.
        let sorted = samples.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let source = sorted.first(where: { $0.source.kind == .appleWatch })?.source ?? sorted[0].source
        let precedence = source.kind == .appleWatch ? watchPrecedence : fallbackPrecedence

        var events: [(time: Date, stage: SleepStage, delta: Int)] = []
        events.reserveCapacity(samples.count * 2)
        for sample in samples {
            events.append((sample.start, sample.stage, 1))
            events.append((sample.end, sample.stage, -1))
        }
        events.sort { $0.time < $1.time }

        var active: [SleepStage: Int] = [:]
        var totals: [SleepStage: TimeInterval] = [:]
        var previous: Date?
        for event in events {
            if let previous, event.time > previous, let stage = precedence.first(where: { (active[$0] ?? 0) > 0 }) {
                totals[stage, default: 0] += event.time.timeIntervalSince(previous)
            }
            active[event.stage, default: 0] += event.delta
            previous = event.time
        }

        let core = totals[.asleepCore] ?? 0
        let deep = totals[.asleepDeep] ?? 0
        let rem = totals[.asleepREM] ?? 0
        let unspecified = totals[.asleepUnspecified] ?? 0
        let hasAsleepSamples = samples.contains { $0.stage.isAsleep }
        let noon = night.date(atHour: 12, calendar: calendar)
        let wokeAt = samples.filter { $0.stage.isAsleep && $0.end <= noon }.map(\.end).max()
        return SleepSummary(
            night: night,
            source: source,
            asleep: hasAsleepSamples ? core + deep + rem + unspecified : nil,
            inBed: totals.values.reduce(0, +),
            core: core,
            deep: deep,
            rem: rem,
            awake: totals[.awake] ?? 0,
            unspecified: unspecified,
            wokeAt: wokeAt,
        )
    }
}
