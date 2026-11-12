import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// Settings → Hydration: stored values, normalization, the bedtime shared with caffeine, the day's waking window and
/// the weight-based goal.
@MainActor
struct HydrationSettingsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        return calendar
    }()

    let today = LocalDay("2026-11-11")!

    /// `hour:minute` on `today` (or `days` later).
    func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: today.startDate(calendar: calendar))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    @Test func `the notifications-off hint shows when reminders are on but permission is gone`() async {
        let denied = RecordingHydrationReminder(authorized: false)
        let allowed = RecordingHydrationReminder(authorized: true)
        #expect(await HydrationSettingsView.notificationsAreOff(remindersEnabled: true, reminder: denied))
        #expect(await !HydrationSettingsView.notificationsAreOff(remindersEnabled: true, reminder: allowed))
        #expect(await !HydrationSettingsView.notificationsAreOff(remindersEnabled: false, reminder: denied))
        #expect(denied.calls.isEmpty) // never asks for permission
    }

    @Test func `defaults when nothing stored`() throws {
        let profiles = try #require(AppEnvironment.preview().profiles)
        let loaded = HydrationSettings.load(from: profiles)
        #expect(loaded == HydrationSettings())
        #expect(loaded.fallbackWakeMinutes == 420)
        #expect(loaded.bedtimeMinutes == CaffeineDefaults.defaultBedtimeMinutes)
        #expect(loaded.gapMinutes == 180)
        #expect(loaded.behindMarginMl == 500)
        #expect(loaded.remindersEnabled == false)
    }

    @Test func `normalizes out of range values`() throws {
        let profiles = try #require(AppEnvironment.preview().profiles)
        try profiles.setSetting(SettingKey.hydrationGapMinutes, 20)
        try profiles.setSetting(SettingKey.hydrationBehindMarginMl, 1200.0)
        try profiles.setSetting(SettingKey.hydrationFallbackWakeMinutes, -60)
        try profiles.setSetting(SettingKey.hydrationRemindersEnabled, "not a bool")
        let loaded = HydrationSettings.load(from: profiles)
        #expect(loaded.gapMinutes == 60)
        #expect(loaded.behindMarginMl == 1000)
        #expect(loaded.fallbackWakeMinutes == 23 * 60)
        #expect(loaded.remindersEnabled == false)

        var settings = HydrationSettings()
        settings.gapMinutes = 200 // stepped to 210
        settings.behindMarginMl = 120 // clamped to 250
        settings.remindersEnabled = true
        let saved = try settings.save(to: profiles)
        #expect(saved.gapMinutes == 210)
        #expect(saved.behindMarginMl == 250)
        #expect(HydrationSettings.load(from: profiles) == saved)
    }

    @Test func `bedtime shared with caffeine`() throws {
        let profiles = try #require(AppEnvironment.preview().profiles)
        var settings = HydrationSettings()
        settings.bedtimeMinutes = 22 * 60 + 30
        try settings.save(to: profiles)
        #expect(CaffeineSettings.load(from: profiles).bedtimeMinutes == 22 * 60 + 30)

        var caffeine = CaffeineSettings.load(from: profiles)
        caffeine.bedtimeMinutes = 60
        try caffeine.save(to: profiles)
        #expect(HydrationSettings.load(from: profiles).bedtimeMinutes == 60)
    }

    @Test func `wake uses health then fallback`() {
        let settings = HydrationSettings() // fallback 07:00
        #expect(settings.wake(on: today, wokeAt: at(6, 12), calendar: calendar) == at(6, 12))
        #expect(settings.wake(on: today, wokeAt: nil, calendar: calendar) == at(7))
        // Woke up yesterday (no sleep recorded for today): the fallback.
        #expect(settings.wake(on: today, wokeAt: at(6, 30, days: -1), calendar: calendar) == at(7))
    }

    @Test func `bedtime after midnight`() {
        var settings = HydrationSettings()
        #expect(settings.bedtime(on: today, calendar: calendar) == at(23))
        settings.bedtimeMinutes = 60 // 01:00 is before the 07:00 wake: the next night
        #expect(settings.bedtime(on: today, calendar: calendar) == at(1, days: 1))
        settings.bedtimeMinutes = settings.fallbackWakeMinutes // same as wake: also the next day
        #expect(settings.bedtime(on: today, calendar: calendar) == at(7, days: 1))
    }

    @Test func `goal follows weight or fixed amount`() throws {
        var profile = try #require(AppEnvironment.preview().profiles).profile()
        profile.waterGoalMode = .weight
        profile.waterGoalMl = 3000
        #expect(HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: 80, training: .none) == 2400)
        #expect(HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: nil, training: .none) == HydrationGoal.fallbackMl)
        profile.waterGoalMode = .fixed
        #expect(HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: 80, training: .none) == 3000)
    }
}
