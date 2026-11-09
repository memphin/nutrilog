import Foundation
@testable import Core

/// Fixed-time-zone helpers for the Health aggregation tests (never `Calendar.current`).
enum HealthFixtures {
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static let zagreb = calendar("Europe/Zagreb")
    static let utc = calendar("UTC")
    static let newYork = calendar("America/New_York")

    static let watch = HealthSource(name: "Ivan's Apple Watch", bundleIdentifier: "com.apple.health.W1", productType: "Watch7,1")
    static let oldWatch = HealthSource(name: "Old Apple Watch", bundleIdentifier: "com.apple.health.W0", productType: "Watch5,1")
    static let iPhone = HealthSource(name: "jaPhone", bundleIdentifier: "com.apple.health.P1", productType: "iPhone17,1")
    static let withings = HealthSource(name: "Withings", bundleIdentifier: "com.withings.wiScaleNG", productType: "iPhone17,1")
    static let sleepApp = HealthSource(name: "AutoSleep", bundleIdentifier: "com.tantsissa.AutoSleep", productType: "iPhone17,1")
    static let healthApp = HealthSource(name: "Health", bundleIdentifier: "com.apple.Health", productType: "iPhone17,1")
    /// A third-party sleep app running on the watch: a watch product type, but not Apple's own source.
    static let watchSleepApp = HealthSource(
        name: "Pillow", bundleIdentifier: "com.neybox.pillow.watchkitapp", productType: "Watch7,1",
    )
}

/// "2026-11-09" → LocalDay.
func day(_ string: String) -> LocalDay {
    LocalDay(string)!
}

/// "2026-11-09 07:30" (or with seconds, "07:30:15") as a local time in `calendar`.
func time(_ string: String, _ calendar: Calendar = HealthFixtures.zagreb) -> Date {
    let parts = string.split(separator: " ")
    let date = day(String(parts[0]))
    let clock = parts[1].split(separator: ":").map { Int($0)! }
    let components = DateComponents(
        year: date.year, month: date.month, day: date.day,
        hour: clock[0], minute: clock[1], second: clock.count > 2 ? clock[2] : 0,
    )
    return calendar.date(from: components)!
}

func sleep(
    _ stage: SleepStage, _ start: String, _ end: String,
    _ source: HealthSource = HealthFixtures.watch, _ calendar: Calendar = HealthFixtures.zagreb,
) -> SleepSample {
    SleepSample(start: time(start, calendar), end: time(end, calendar), stage: stage, source: source)
}

func quantity(
    _ value: Double,
    at start: String,
    _ source: HealthSource,
    _ calendar: Calendar = HealthFixtures.zagreb,
) -> HealthQuantitySample {
    HealthQuantitySample(start: time(start, calendar), value: value, source: source)
}

/// A statistic covering exactly one local day, as a daily statistics collection query returns it.
func dailyStatistic(
    _ dayString: String, _ sum: Double, sources: [SourceContribution] = [],
    _ calendar: Calendar = HealthFixtures.zagreb,
) -> CumulativeStatistic {
    let interval = day(dayString).dateInterval(calendar: calendar)
    return CumulativeStatistic(start: interval.start, end: interval.end, sum: sum, sources: sources)
}

/// A typical Apple Watch night ending on 2026-11-09: 465 min asleep (core 330, deep 60, REM 75), 15 min awake,
/// 480 min in total.
func watchNight(_ source: HealthSource = HealthFixtures.watch) -> [SleepSample] {
    [
        sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 01:00", source),
        sleep(.asleepDeep, "2026-11-09 01:00", "2026-11-09 02:00", source),
        sleep(.asleepREM, "2026-11-09 02:00", "2026-11-09 03:00", source),
        sleep(.awake, "2026-11-09 03:00", "2026-11-09 03:15", source),
        sleep(.asleepCore, "2026-11-09 03:15", "2026-11-09 06:45", source),
        sleep(.asleepREM, "2026-11-09 06:45", "2026-11-09 07:00", source),
    ]
}

extension SleepSummary {
    var asleepMinutes: Int? {
        asleep.map { Int(($0 / 60).rounded()) }
    }

    var inBedMinutes: Int {
        Int((inBed / 60).rounded())
    }

    func minutes(_ keyPath: KeyPath<SleepSummary, TimeInterval>) -> Int {
        Int((self[keyPath: keyPath] / 60).rounded())
    }
}
