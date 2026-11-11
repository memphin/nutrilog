import Core
import Foundation
import Persistence

// MARK: - Settings

/// Settings → Hydration: the waking window (a fallback wake-up time, bedtime shared with caffeine), when a stretch
/// without a drink is a gap, how far below pace counts as behind, and whether reminders are on. Each value is its own
/// `SettingKey`; missing or unusable values fall back to the defaults. The goal itself lives on `Profile`.
struct HydrationSettings: Equatable {
    static let gapRange = 60 ... 360
    static let gapStep = 30
    static let marginRange = 250.0 ... 1000
    static let marginStep = 50.0

    /// Minutes from midnight; used when Apple Health has no wake-up time for the day.
    var fallbackWakeMinutes = 420
    /// Minutes from midnight. Stored as `SettingKey.caffeineBedtimeMinutes`: one bedtime for caffeine and hydration.
    var bedtimeMinutes = CaffeineDefaults.defaultBedtimeMinutes
    var gapMinutes = 180
    var behindMarginMl = 500.0
    var remindersEnabled = false

    static let `default` = HydrationSettings()

    var gapThreshold: TimeInterval {
        TimeInterval(gapMinutes * 60)
    }

    /// 0 ..< 24 h.
    static func normalizedMinutesOfDay(_ minutes: Int) -> Int {
        CaffeineSettings.normalizedBedtime(minutes)
    }

    /// In `gapRange`, on a `gapStep` step.
    static func normalizedGap(_ minutes: Int) -> Int {
        let stepped = Int((Double(minutes) / Double(gapStep)).rounded()) * gapStep
        return min(max(stepped, gapRange.lowerBound), gapRange.upperBound)
    }

    /// In `marginRange`, on a `marginStep` step.
    static func normalizedMargin(_ ml: Double) -> Double {
        guard ml.isFinite else { return HydrationSettings.default.behindMarginMl }
        let stepped = (ml / marginStep).rounded() * marginStep
        return min(max(stepped, marginRange.lowerBound), marginRange.upperBound)
    }

    static func load(from settings: ProfileRepository) -> HydrationSettings {
        func read<T: Codable & Sendable>(_ key: String, _: T.Type) -> T? {
            (try? settings.setting(key, as: T.self)) ?? nil
        }
        var result = HydrationSettings()
        if let minutes = read(SettingKey.hydrationFallbackWakeMinutes, Int.self) {
            result.fallbackWakeMinutes = normalizedMinutesOfDay(minutes)
        }
        if let minutes = read(SettingKey.caffeineBedtimeMinutes, Int.self) {
            result.bedtimeMinutes = normalizedMinutesOfDay(minutes)
        }
        if let minutes = read(SettingKey.hydrationGapMinutes, Int.self) {
            result.gapMinutes = normalizedGap(minutes)
        }
        if let ml = read(SettingKey.hydrationBehindMarginMl, Double.self) {
            result.behindMarginMl = normalizedMargin(ml)
        }
        if let enabled = read(SettingKey.hydrationRemindersEnabled, Bool.self) {
            result.remindersEnabled = enabled
        }
        return result
    }

    /// Saves every value, normalized; returns what was saved.
    @discardableResult
    func save(to settings: ProfileRepository) throws -> HydrationSettings {
        var saved = self
        saved.fallbackWakeMinutes = Self.normalizedMinutesOfDay(fallbackWakeMinutes)
        saved.bedtimeMinutes = Self.normalizedMinutesOfDay(bedtimeMinutes)
        saved.gapMinutes = Self.normalizedGap(gapMinutes)
        saved.behindMarginMl = Self.normalizedMargin(behindMarginMl)
        try settings.setSetting(SettingKey.hydrationFallbackWakeMinutes, saved.fallbackWakeMinutes)
        try settings.setSetting(SettingKey.caffeineBedtimeMinutes, saved.bedtimeMinutes)
        try settings.setSetting(SettingKey.hydrationGapMinutes, saved.gapMinutes)
        try settings.setSetting(SettingKey.hydrationBehindMarginMl, saved.behindMarginMl)
        try settings.setSetting(SettingKey.hydrationRemindersEnabled, saved.remindersEnabled)
        return saved
    }

    // MARK: Waking window

    /// When the day starts: `wokeAt` (Apple Health sleep) when it falls on `day`, else the fallback wake-up time.
    func wake(on day: LocalDay, wokeAt: Date?, calendar: Calendar) -> Date {
        if let wokeAt, LocalDay(wokeAt, calendar: calendar) == day {
            return wokeAt
        }
        return Self.time(minutes: fallbackWakeMinutes, on: day, calendar: calendar)
    }

    /// When the day ends: bedtime on `day`, or on the next day when it is not after the fallback wake-up time
    /// (a 01:00 bedtime belongs to the night after `day`).
    func bedtime(on day: LocalDay, calendar: Calendar) -> Date {
        let night = bedtimeMinutes <= fallbackWakeMinutes ? day.next : day
        return Self.time(minutes: bedtimeMinutes, on: night, calendar: calendar)
    }

    /// `minutes` past midnight on `day`.
    private static func time(minutes: Int, on day: LocalDay, calendar: Calendar) -> Date {
        let minutes = normalizedMinutesOfDay(minutes)
        let start = day.startDate(calendar: calendar)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start)
            ?? start.addingTimeInterval(TimeInterval(minutes * 60))
    }
}

// MARK: - Goal

/// The day's hydration goal (spec §1): 30 ml/kg of the latest weight trend on or before the day, however old (weight
/// mode), or the fixed amount. The one goal lookup: Today's tile and detail, Settings and the reminders all read the
/// weight with `trendsKg(in:from:)` and the goal with `goalMl`, so they always agree.
enum HydrationGoalResolver {
    /// The weight each day's goal uses: the latest stored trend on or before the day, also one from before `days`
    /// (`DailyMetricsRepository.weightTrends(in:)`). Days before the first trend are absent; so is everything when
    /// the trends can't be read (the goal then falls back like without a weight).
    static func trendsKg(in days: ClosedRange<LocalDay>, from metrics: DailyMetricsRepository?) -> [LocalDay: Double] {
        (try? metrics?.weightTrends(in: days)) ?? [:]
    }

    /// `trendKg` is the weight trend on or before `day` (nil when none is known: the fallback goal).
    static func goalMl(on day: LocalDay, profile: Profile, trendKg: Double?) -> Double {
        goalMl(on: day, mode: profile.waterGoalMode, fixedMl: profile.waterGoalMl, trendKg: trendKg)
    }

    /// The same, with the profile's goal mode and fixed amount given separately.
    static func goalMl(on _: LocalDay, mode: HydrationGoalMode, fixedMl: Double, trendKg: Double?) -> Double {
        HydrationGoal.ml(weightKg: trendKg, mode: mode, fixedMl: fixedMl)
    }
}
