import Core
import Foundation
import Persistence
import Synchronization
import Testing
import UserNotifications
@testable import Vitalion

/// Records the supplement reminders the service hands to the notification center.
final class RecordingSupplementReminder: SupplementReminderScheduling {
    private let state: Mutex<(authorized: Bool, replaced: [[SupplementNotification]], openSlots: Set<SupplementSlot>)>

    init(authorized: Bool = true) {
        state = Mutex((authorized, [], []))
    }

    /// The pending notifications after the last replace.
    var current: [SupplementNotification] {
        state.withLock { $0.replaced.last ?? [] }
    }

    var replaceCount: Int {
        state.withLock { $0.replaced.count }
    }

    var openSlots: Set<SupplementSlot> {
        state.withLock { $0.openSlots }
    }

    func requestAuthorization() async -> Bool {
        state.withLock { $0.authorized }
    }

    func isAuthorized() async -> Bool {
        state.withLock { $0.authorized }
    }

    func replace(with notifications: [SupplementNotification], openSlots: Set<SupplementSlot>) async {
        state.withLock {
            $0.replaced.append(notifications)
            $0.openSlots = openSlots
        }
    }
}

/// Supplement reminders: planned from the supplements and the doses logged, with the "Taken" and "Snooze" actions.
@MainActor
struct SupplementReminderServiceTests {
    let clock = ManualClock(day: "2026-11-11") // 12:00
    let calendar = Calendar.current
    let today = LocalDay("2026-11-11")!
    let env: AppEnvironment
    let scheduler = RecordingSupplementReminder()

    init() {
        env = AppEnvironment.preview(clock: clock.appClock)
    }

    func makeService(scheduler: RecordingSupplementReminder? = nil) throws -> SupplementReminderService {
        try SupplementReminderService(
            supplements: #require(env.supplements),
            profiles: #require(env.profiles),
            scheduler: scheduler ?? self.scheduler,
            clock: clock.appClock,
            calendar: calendar,
            locale: Locale(identifier: "en_GB"),
        )
    }

    @discardableResult
    func add(_ name: String, dose: String = "", times: [Int], reminders: Bool = true) throws -> Supplement {
        try #require(env.supplements).save(Supplement(
            name: name, dose: dose, schedule: SupplementSchedule(times: times), startDay: today, remindersEnabled: reminders,
        ))
    }

    func slot(_ minute: Int, days: Int = 0) -> SupplementSlot {
        SupplementSlot(day: today.adding(days: days), minute: minute)
    }

    @Test func `plans each slot and its follow-up for the next days`() async throws {
        try add("Vitamin D3", dose: "2000 IU", times: [13 * 60])
        try add("Omega-3", times: [13 * 60])
        try add("Quiet", times: [14 * 60], reminders: false)
        try await makeService().recompute()

        let first = try #require(scheduler.current.first)
        #expect(first.identifier == "supplement:2026-11-11:780:due")
        #expect(first.fireDate == slot(780).date(calendar: calendar))
        #expect(first.title == "Time to take")
        #expect(first.body == "Vitamin D3 · 2000 IU and Omega-3")
        let followUp = scheduler.current[1]
        #expect(followUp.identifier == "supplement:2026-11-11:780:followUp")
        #expect(followUp.title == "Not taken yet")
        #expect(followUp.body == "Due at 13:00: Vitamin D3 · 2000 IU and Omega-3")
        // Today and the next 6 days, two notifications each; nothing for the supplement without reminders.
        #expect(scheduler.current.count == 14)
        #expect(scheduler.current.allSatisfy { !$0.body.contains("Quiet") })
    }

    @Test func `the Taken action logs the slot's doses and drops its reminders`() async throws {
        let d3 = try add("Vitamin D3", times: [11 * 60])
        let service = try makeService()
        try await service.recompute()
        // 11:00 and its 12:00 follow-up have passed, but the dose is still open.
        #expect(scheduler.openSlots.contains(slot(660)))

        await service.handleTaken(slot(660))
        let doses = try #require(env.supplements).day(today).doses
        #expect(doses.map(\.supplementID) == [d3.id])
        #expect(doses.first?.status == .taken)
        #expect(!scheduler.openSlots.contains(slot(660)))
    }

    @Test func `snoozing reminds once more after 15 minutes`() async throws {
        try add("Vitamin D3", times: [11 * 60 + 30]) // follow-up at 12:30
        let service = try makeService()
        await service.handleSnooze(slot(690))
        let snoozed = scheduler.current.filter { $0.identifier.hasPrefix("supplement:2026-11-11:690") }
        #expect(snoozed.map(\.identifier) == ["supplement:2026-11-11:690:snoozed"])
        #expect(snoozed.first?.fireDate == clock.appClock.now().addingTimeInterval(15 * 60))
    }

    @Test func `switched off or without permission, nothing is pending`() async throws {
        try add("Vitamin D3", times: [13 * 60])
        try #require(env.profiles).setSetting(SettingKey.supplementRemindersEnabled, false)
        try await makeService().recompute()
        #expect(scheduler.current.isEmpty)

        try #require(env.profiles).setSetting(SettingKey.supplementRemindersEnabled, true)
        let denied = RecordingSupplementReminder(authorized: false)
        try await makeService(scheduler: denied).recompute()
        #expect(denied.replaceCount == 1)
        #expect(denied.current.isEmpty)
    }

    @Test func `notification identifiers and actions`() {
        let slot = SupplementSlot(day: today, minute: 480)
        let id = SupplementNotificationID.make(slot, .followUp)
        #expect(SupplementNotificationID.parse(id)?.slot == slot)
        #expect(SupplementNotificationID.parse(id)?.kind == .followUp)
        #expect(SupplementNotificationID.parse("supplement:2026-11-11:1440:due") == nil)
        #expect(SupplementNotificationID.parse("hydration-reminder") == nil)

        let taken = LocalNotificationSupplementReminder.takenActionIdentifier
        let snooze = LocalNotificationSupplementReminder.snoozeActionIdentifier
        #expect(NotificationDelegate.action(identifier: id, actionIdentifier: taken) == .supplementTaken(slot))
        #expect(NotificationDelegate.action(identifier: id, actionIdentifier: snooze) == .supplementSnooze(slot))
        #expect(NotificationDelegate.action(identifier: id, actionIdentifier: UNNotificationDefaultActionIdentifier) == .openSupplements(today))
        #expect(NotificationDelegate.action(identifier: id, actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
        #expect(NotificationDelegate.presentationOptions(identifier: id) == [.banner, .sound])
    }

    @Test func `schedule summary`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        #expect(SupplementFormat.schedule(.asNeeded, calendar: calendar) == "As needed")
        #expect(SupplementFormat.weekdayOrder(calendar) == [2, 3, 4, 5, 6, 7, 1])
        let summary = SupplementFormat.schedule(SupplementSchedule(times: [480], weekdays: [1, 2]), calendar: calendar)
        #expect(summary.hasSuffix("Mon, Sun"))
    }
}

/// The diary's supplements section.
@MainActor
struct DiarySupplementsTests {
    let clock = ManualClock(day: "2026-11-11") // 12:00
    let today = LocalDay("2026-11-11")!

    @Test func `ticking, skipping and logging extra doses`() async throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let repo = try #require(env.supplements)
        let d3 = try repo.save(Supplement(name: "Vitamin D3", schedule: SupplementSchedule(times: [480]), startDay: today))
        try repo.save(Supplement(name: "Magnesium", schedule: SupplementSchedule(times: [1260]), startDay: today))
        let ibu = try repo.save(Supplement(name: "Ibuprofen", schedule: .asNeeded, startDay: today))

        let model = DiaryModel(environment: env)
        let observing = Task { await model.observeSupplements() }
        defer { observing.cancel() }
        #expect(await waitUntil { model.supplementDay?.rows.count == 2 })
        let rows = try #require(model.supplementDay?.rows)
        #expect(model.isOverdue(rows[0])) // 08:00, now 12:00
        #expect(!model.isOverdue(rows[1]))

        model.toggleTaken(rows[0])
        #expect(await waitUntil { model.supplementDay?.rows.first?.isTaken == true })
        #expect(model.supplementDay?.rows.first?.dose?.takenAt == clock.appClock.now())
        model.toggleTaken(try #require(model.supplementDay?.rows.first)) // untick
        #expect(await waitUntil { model.supplementDay?.rows.first?.dose == nil })

        model.markSkipped(rows[1])
        model.logExtraDose(ibu)
        #expect(await waitUntil { model.supplementDay?.rows.count == 3 })
        #expect(model.supplementDay?.rows[1].isSkipped == true)
        #expect(model.supplementDay?.rows[2].supplement.id == ibu.id)

        model.markAllTaken()
        #expect(await waitUntil { model.supplementDay?.rows.first?.isTaken == true })
        #expect(model.supplementDay?.rows[1].isSkipped == true) // a skipped dose stays skipped
        #expect(try #require(model.supplementDay).progress == (1, 2))
        _ = d3
    }

    @Test func `on a past day a dose counts at its own time`() throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = DiaryModel(environment: env, day: today.previous)
        #expect(model.takenTime(for: 480) == SupplementSlot(day: today.previous, minute: 480).date(calendar: .autoupdatingCurrent))
    }
}
