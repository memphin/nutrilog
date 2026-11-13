import Core
import Foundation
import Persistence
import Synchronization
import Testing
import UserNotifications
@testable import Vitalion

/// Records what the reminder service asks of the notification center. Like iOS, it refuses to schedule without
/// permission.
final class RecordingHydrationReminder: HydrationReminderScheduling {
    enum Call: Equatable {
        case schedule(at: Date, title: String, body: String, actionTitle: String)
        case cancel
        case requestAuthorization
    }

    struct NotAuthorized: Error {}

    private let state: Mutex<(authorized: Bool, calls: [Call])>

    init(authorized: Bool) {
        state = Mutex((authorized, []))
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    var scheduled: [Call] {
        calls.filter {
            if case .schedule = $0 {
                true
            } else {
                false
            }
        }
    }

    var scheduledDates: [Date] {
        scheduled.compactMap {
            if case let .schedule(date, _, _, _) = $0 {
                date
            } else {
                nil
            }
        }
    }

    func requestAuthorization() async -> Bool {
        state.withLock { state in
            state.calls.append(.requestAuthorization)
            return state.authorized
        }
    }

    func isAuthorized() async -> Bool {
        state.withLock { $0.authorized }
    }

    func schedule(at date: Date, title: String, body: String, actionTitle: String) async throws {
        try state.withLock { state in
            guard state.authorized else { throw NotAuthorized() }
            state.calls.append(.schedule(at: date, title: title, body: body, actionTitle: actionTitle))
        }
    }

    func cancel() async {
        state.withLock { $0.calls.append(.cancel) }
    }
}

/// Hydration reminders (spec §4): one notification at the earlier of "no drink for the gap threshold" and "behind
/// pace by the margin", with the exact copy, rescheduled as drinks arrive, and the "+ 250 ml" action.
/// The day runs 07:00 (fallback wake-up) to 23:00 (default bedtime): pace reaches the 2,500 ml fallback goal at 22:00.
@MainActor
struct HydrationReminderServiceTests {
    let clock = ManualClock(day: "2026-11-11") // 12:00
    let calendar = Calendar.current
    let today = LocalDay("2026-11-11")!
    let env: AppEnvironment
    let scheduler: RecordingHydrationReminder

    init() throws {
        env = AppEnvironment.preview(clock: clock.appClock)
        scheduler = RecordingHydrationReminder(authorized: true)
        try setReminders(on: true)
    }

    func makeService(
        scheduler: RecordingHydrationReminder? = nil, defaults: UserDefaults? = nil,
    ) throws -> HydrationReminderService {
        try HydrationReminderService(
            hydration: #require(env.hydration),
            metrics: #require(env.dailyMetrics),
            profiles: #require(env.profiles),
            water: #require(env.water),
            weights: #require(env.weights),
            trainingDays: #require(env.trainingDays),
            scheduler: scheduler ?? self.scheduler,
            clock: clock.appClock,
            calendar: calendar,
            // English with 24-hour times, so the copy reads "No drink since 11:00 · 2,000 of 2,500 ml".
            locale: Locale(identifier: "en_GB"),
            defaults: defaults,
        )
    }

    func setReminders(on: Bool) throws {
        var settings = HydrationSettings.default
        settings.remindersEnabled = on
        try settings.save(to: #require(env.profiles))
    }

    /// `hour:minute` on `today` (or `days` later).
    func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: today.startDate(calendar: calendar))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func drink(_ ml: Double, at date: Date) throws {
        try #require(env.water).add(ml: ml, day: LocalDay(date, calendar: calendar), loggedAt: date)
    }

    @Test func `reminders off cancels and never asks`() async throws {
        try setReminders(on: false)
        try drink(200, at: at(8))
        try await makeService().recompute()
        #expect(scheduler.calls == [.cancel])
    }

    @Test func `without notification permission it cancels and does not throw`() async throws {
        let denied = RecordingHydrationReminder(authorized: false)
        try drink(200, at: at(8))
        try await makeService(scheduler: denied).recompute()
        #expect(denied.calls == [.cancel])
    }

    @Test func `schedules the gap reminder with its copy`() async throws {
        try drink(2000, at: at(11))
        try await makeService().recompute()
        #expect(scheduler.calls == [.schedule(
            at: at(14), title: "Time for a drink", body: "No drink since 11:00 · 2,000 of 2,500 ml", actionTitle: "+ 250 ml",
        )])
    }

    @Test func `schedules the behind reminder when pace runs away first`() async throws {
        // 500 ml at 11:55: the gap ends at 14:55, but pace reaches 500 + 500 ml at 13:00.
        try drink(500, at: at(11, 55))
        try await makeService().recompute()
        #expect(scheduler.calls == [.schedule(
            at: at(13), title: "You're behind on hydration",
            body: "500 ml so far — about 1,000 by now keeps you on track", actionTitle: "+ 250 ml",
        )])
    }

    @Test func `the behind amount is rounded to 50 ml`() async throws {
        // 100 ml at 11:30: pace reached 600 ml at 10:36, so the reminder is due now, when pace is at 833 ml.
        try drink(100, at: at(11, 30))
        try await makeService().recompute()
        #expect(scheduler.calls == [.schedule(
            at: at(12), title: "You're behind on hydration",
            body: "100 ml so far — about 850 by now keeps you on track", actionTitle: "+ 250 ml",
        )])
    }

    @Test func `goal reached cancels`() async throws {
        try drink(2500, at: at(11))
        try await makeService().recompute()
        #expect(scheduler.calls == [.cancel])
    }

    @Test func `a training day raises the goal the reminder plans for`() async throws {
        try #require(env.trainingDays).toggleTraining(on: today) // no schedule: a training day
        // 2,500 ml reaches the base goal, not the training day's 2,750 ml.
        try drink(2500, at: at(11))
        try await makeService().recompute()
        #expect(scheduler.calls == [.schedule(
            at: at(14), title: "Time for a drink", body: "No drink since 11:00 · 2,500 of 2,750 ml", actionTitle: "+ 250 ml",
        )])
    }

    @Test func `a reminder already due fires once, not on every recompute`() async throws {
        // No drink since waking: the gap reminder (10:00) is overdue, so it is due now.
        let service = try makeService()
        await service.recompute()
        #expect(scheduler.scheduled == [.schedule(
            at: at(12), title: "Time for a drink", body: "No drink since 07:00 · 0 of 2,500 ml", actionTitle: "+ 250 ml",
        )])
        await service.recompute()
        #expect(scheduler.calls.count == 1)

        // Also after a relaunch (a new service with the same stored record).
        let suite = "HydrationReminderServiceTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await makeService(defaults: defaults).recompute()
        #expect(scheduler.calls.count == 2)
        let relaunched = try makeService(defaults: defaults)
        await relaunched.recompute()
        #expect(scheduler.calls.count == 2)

        // A new drink starts a new stretch.
        try drink(300, at: at(12))
        await relaunched.recompute()
        #expect(scheduler.calls.count == 3)
    }

    @Test func `adding a drink reschedules`() async throws {
        let service = try makeService()
        service.start()
        defer { service.stop() }
        #expect(await waitUntil { !scheduler.scheduled.isEmpty })
        try drink(1500, at: at(12))
        let expected = RecordingHydrationReminder.Call.schedule(
            at: at(15), title: "Time for a drink", body: "No drink since 12:00 · 1,500 of 2,500 ml", actionTitle: "+ 250 ml",
        )
        #expect(await waitUntil { scheduler.scheduled.last == expected })
    }

    @Test func `a weight logged in Vitalion without Apple Health sets the goal`() async throws {
        let service = try makeService()
        service.start()
        defer { service.stop() }
        try drink(2000, at: at(11))
        #expect(await waitUntil { scheduler.scheduled.last == .schedule(
            at: at(14), title: "Time for a drink", body: "No drink since 11:00 · 2,000 of 2,500 ml", actionTitle: "+ 250 ml",
        ) })

        try #require(env.weights).add(kg: 80, measuredAt: at(7))
        let expected = RecordingHydrationReminder.Call.schedule(
            at: at(14), title: "Time for a drink", body: "No drink since 11:00 · 2,000 of 2,400 ml", actionTitle: "+ 250 ml",
        )
        #expect(await waitUntil { scheduler.scheduled.last == expected })
    }

    @Test func `the add action logs the smallest size and reschedules`() async throws {
        let profiles = try #require(env.profiles)
        try WaterQuickAdd.save([500, 300], to: profiles)
        try drink(1500, at: at(11))
        try await makeService().handleAddAction()

        let entries = try #require(env.water).entries(for: today)
        #expect(entries.map(\.ml) == [1500, 300])
        #expect(entries.last?.loggedAt == at(12))
        #expect(scheduler.scheduled.last == .schedule(
            at: at(15), title: "Time for a drink", body: "No drink since 12:00 · 1,800 of 2,500 ml", actionTitle: "+ 300 ml",
        ))
    }

    @Test func `after midnight it plans for the new day`() async throws {
        try drink(2000, at: at(11))
        let service = try makeService()
        service.start()
        defer { service.stop() }
        #expect(await waitUntil { scheduler.scheduledDates.last == at(14) })

        clock.advance(hours: 13) // 01:00 the next day
        await service.recompute()
        let newDay = RecordingHydrationReminder.Call.schedule(
            at: at(10, days: 1), title: "Time for a drink", body: "No drink since 07:00 · 0 of 2,500 ml", actionTitle: "+ 250 ml",
        )
        #expect(scheduler.scheduled.last == newDay)

        // The day change restarts the observation: a drink on the new day reschedules.
        service.start()
        try drink(250, at: at(0, 30, days: 1))
        let afterDrink = RecordingHydrationReminder.Call.schedule(
            at: at(10, days: 1), title: "Time for a drink", body: "No drink since 07:00 · 250 of 2,500 ml", actionTitle: "+ 250 ml",
        )
        #expect(await waitUntil { scheduler.scheduled.last == afterDrink })
    }

    @Test func `a Health sync after midnight plans the new day without a restart`() async throws {
        let service = try makeService()
        service.start()
        defer { service.stop() }
        #expect(await waitUntil { !scheduler.scheduled.isEmpty })

        // The app stays suspended past midnight; nothing calls `start()` again. A background Health sync then
        // writes the new day's wake-up time.
        clock.advance(hours: 13) // 01:00 the next day
        let tomorrow = today.next
        try #require(env.dailyMetrics).upsert([DailyHealthMetrics(day: tomorrow, wokeAt: at(8, 30, days: 1))])

        // Woken at 08:30, pace (to 22:00) reaches 500 ml at 11:12, before the 11:30 gap.
        #expect(await waitUntil {
            guard case let .schedule(date, title, body, _) = scheduler.scheduled.last else { return false }
            return abs(date.timeIntervalSince(at(11, 12, days: 1))) < 1 && title == "You're behind on hydration"
                && body == "0 ml so far — about 500 by now keeps you on track"
        })
    }

    @Test func `late in the evening it plans tomorrow's first reminder`() async throws {
        try drink(2000, at: at(20, 30))
        clock.advance(hours: 9) // 21:00: the gap would end after the pace line (22:00)
        try await makeService().recompute()
        #expect(scheduler.calls == [.schedule(
            at: at(10, days: 1), title: "Time for a drink", body: "No drink since 07:00 · 0 of 2,500 ml", actionTitle: "+ 250 ml",
        )])
    }

    @Test func `the environment's add action logs water through its reminder service`() async throws {
        let reminder = RecordingHydrationReminder(authorized: true)
        let env = AppEnvironment.preview(clock: clock.appClock, hydrationReminder: reminder)
        var settings = HydrationSettings.default
        settings.remindersEnabled = true
        try settings.save(to: #require(env.profiles))

        await env.handleHydrationAddAction()
        #expect(try #require(env.water).entries(for: today).map(\.ml) == [250])
        #expect(reminder.scheduledDates.last != nil)
    }

    @Test func `the notification delegate routes only the hydration reminder`() {
        let reminder = LocalNotificationHydrationReminder.identifier
        let add = LocalNotificationHydrationReminder.addActionIdentifier
        #expect(NotificationDelegate.action(identifier: reminder, actionIdentifier: add) == .addWater)
        let tap = UNNotificationDefaultActionIdentifier, dismiss = UNNotificationDismissActionIdentifier
        #expect(NotificationDelegate.action(identifier: reminder, actionIdentifier: tap) == .openHydration)
        #expect(NotificationDelegate.action(identifier: reminder, actionIdentifier: dismiss) == nil)
        // Other notifications (the weekly check-in) are left alone, whatever the action.
        #expect(NotificationDelegate.action(identifier: "weekly-check-in", actionIdentifier: tap) == nil)
        #expect(NotificationDelegate.action(identifier: "weekly-check-in", actionIdentifier: add) == nil)
        #expect(NotificationDelegate.presentationOptions(identifier: reminder) == [.banner, .sound])
        #expect(NotificationDelegate.presentationOptions(identifier: "weekly-check-in") == [])
    }

    @Test func `the reminder's time and amounts follow the locale`() {
        let since = at(13)
        let us = HydrationReminderCopy.body(
            .gap(since: since), totalMl: 1320, goalMl: 2400, calendar: calendar, locale: Locale(identifier: "en_US"),
        )
        #expect(us.hasPrefix("No drink since 01:00"))
        #expect(us.hasSuffix("PM · 1,320 of 2,400 ml"))
        let croatian = HydrationReminderCopy.body(
            .gap(since: since), totalMl: 1320, goalMl: 2400, calendar: calendar, locale: Locale(identifier: "hr_HR"),
        )
        #expect(croatian.contains("13:00"))
        #expect(croatian.contains("1.320"))
    }

    @Test func `tapping the reminder opens the Hydration detail on Today`() {
        env.selectedTab = .settings
        env.openDashboardTile(.water)
        #expect(env.selectedTab == .today)
        #expect(env.dashboardTileRequest == .water)
    }
}
