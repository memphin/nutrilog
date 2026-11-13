import Core
import Foundation
import Persistence

/// Keeps the supplement reminders in line with the supplements and the doses logged: plans them with Core
/// `SupplementReminderPlanner` for the next days and hands them to the scheduler, which replaces the pending ones.
///
/// Recomputes whenever a supplement or a dose of the planned days changes while `start()`ed; `AppEnvironment` also
/// asks after launch, foreground, imports, day changes and settings changes. Cancels everything when reminders are
/// off or notifications are not allowed. Reminders run out after ``SupplementReminderPlanner/horizonDays`` without
/// opening the app.
@MainActor
final class SupplementReminderService {
    nonisolated static let snoozeMinutes = 15
    private static let snoozedKey = "supplementReminder.snoozed"

    private let supplements: SupplementRepository
    private let profiles: ProfileRepository
    private let scheduler: any SupplementReminderScheduling
    private let clock: AppClock
    private let calendar: Calendar
    private let locale: Locale
    private let defaults: UserDefaults?

    /// Slots the user snoozed and until when; kept in `defaults` when given.
    private var snoozed: [SupplementSlot: Date]
    private var observation: Task<Void, Never>?
    private var observedDay: LocalDay?
    private var pending: Task<Void, Never>?

    init(
        supplements: SupplementRepository,
        profiles: ProfileRepository,
        scheduler: any SupplementReminderScheduling,
        clock: AppClock,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        defaults: UserDefaults? = nil,
    ) {
        self.supplements = supplements
        self.profiles = profiles
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
        self.locale = locale
        self.defaults = defaults
        let stored = defaults?.data(forKey: Self.snoozedKey).flatMap { try? JSONDecoder().decode([Snooze].self, from: $0) } ?? []
        snoozed = Dictionary(stored.map { ($0.slot, $0.until) }) { first, _ in first }
    }

    private struct Snooze: Codable {
        var slot: SupplementSlot
        var until: Date
    }

    deinit {
        observation?.cancel()
    }

    /// The days planned: yesterday (for delivered reminders of open doses) through the planning horizon.
    private func days(from today: LocalDay) -> ClosedRange<LocalDay> {
        today.previous ... today.adding(days: SupplementReminderPlanner.horizonDays - 1)
    }

    // MARK: Observing

    /// Recomputes whenever a supplement or a dose of the planned days changes. Call again after the day changed: it
    /// then observes the new days; otherwise it does nothing.
    func start() {
        let today = LocalDay(clock.now(), calendar: calendar)
        guard observation == nil || observedDay != today else { return }
        observation?.cancel()
        observedDay = today
        let supplements = supplements
        let days = days(from: today)
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.enqueueRecompute() }
        observation = Task {
            await DiaryModel.resubscribing {
                supplements.observeReminderInput(in: days)
            } onValue: { _ in
                changed()
            } onError: { _ in }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        observedDay = nil
    }

    // MARK: Actions

    /// The notification's "Taken": logs the slot's open reminded doses as taken now.
    func handleTaken(_ slot: SupplementSlot) async {
        if let input = try? supplements.reminderInput(in: slot.day ... slot.day) {
            let keys = Self.openKeys(input, slot: slot)
            try? supplements.markTaken(keys, at: clock.now())
        }
        snoozed[slot] = nil
        saveSnoozed()
        await recompute()
    }

    /// The notification's "Snooze": reminds of the slot again in ``snoozeMinutes``.
    func handleSnooze(_ slot: SupplementSlot) async {
        snoozed[slot] = clock.now().addingTimeInterval(Double(Self.snoozeMinutes) * 60)
        saveSnoozed()
        await recompute()
    }

    // MARK: Recomputing

    func recompute() async {
        await enqueueRecompute().value
    }

    @discardableResult
    func enqueueRecompute() -> Task<Void, Never> {
        let previous = pending
        let task = Task { [weak self] in
            await previous?.value
            await self?.apply()
        }
        pending = task
        return task
    }

    private func apply() async {
        if observation != nil {
            start() // past midnight: observe the new days
        }
        let enabled = (try? profiles.setting(SettingKey.supplementRemindersEnabled, as: Bool.self)) ?? nil
        guard enabled ?? true, await scheduler.isAuthorized() else {
            await scheduler.replace(with: [], openSlots: [])
            return
        }
        let now = clock.now()
        let today = LocalDay(now, calendar: calendar)
        guard let input = try? supplements.reminderInput(in: days(from: today)) else { return } // unreadable: leave as is
        snoozed = snoozed.filter { $0.value > now }
        saveSnoozed()
        let reminders = SupplementReminderPlanner.plan(
            items: input.items, handled: input.handled, snoozed: snoozed, now: now, calendar: calendar,
        )
        let notifications = reminders.map { reminder in
            SupplementNotification(
                identifier: SupplementNotificationID.make(reminder.slot, reminder.kind),
                fireDate: reminder.fireDate,
                title: SupplementReminderCopy.title(reminder.kind),
                body: SupplementReminderCopy.body(reminder, calendar: calendar, locale: locale),
            )
        }
        await scheduler.replace(with: notifications, openSlots: Self.openSlots(input, days: today.previous ... today))
    }

    /// The doses at `slot` that are reminded of and still open.
    static func openKeys(_ input: SupplementReminderInput, slot: SupplementSlot) -> [SupplementDoseKey] {
        input.items
            .filter { slot.day >= $0.startDay && $0.schedule.times(on: slot.day).contains(slot.minute) }
            .map { SupplementDoseKey(supplementID: $0.id, slot: slot) }
            .filter { !input.handled.contains($0) }
    }

    /// The slots of `days` with an open reminded dose: their delivered notifications stay in Notification Center.
    static func openSlots(_ input: SupplementReminderInput, days: ClosedRange<LocalDay>) -> Set<SupplementSlot> {
        var result: Set<SupplementSlot> = []
        for day in days.days {
            for item in input.items where day >= item.startDay {
                for minute in item.schedule.times(on: day) {
                    let slot = SupplementSlot(day: day, minute: minute)
                    if !input.handled.contains(SupplementDoseKey(supplementID: item.id, slot: slot)) {
                        result.insert(slot)
                    }
                }
            }
        }
        return result
    }

    private func saveSnoozed() {
        guard let defaults else { return }
        let list = snoozed.map { Snooze(slot: $0.key, until: $0.value) }
        if list.isEmpty {
            defaults.removeObject(forKey: Self.snoozedKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.snoozedKey)
        }
    }
}

// MARK: - App

extension SupplementReminderService {
    convenience init(database: AppDatabase, scheduler: any SupplementReminderScheduling, clock: AppClock, defaults: UserDefaults?) {
        self.init(
            supplements: SupplementRepository(database, clock: clock),
            profiles: ProfileRepository(database, clock: clock),
            scheduler: scheduler,
            clock: clock,
            defaults: defaults,
        )
    }
}

extension AppEnvironment {
    var supplements: SupplementRepository? {
        db.map { SupplementRepository($0, clock: clock) }
    }

    /// Plans the supplement reminders again (and follows the new day after midnight). Never asks for permission.
    func refreshSupplementReminders() {
        supplementReminderService?.start()
        supplementReminderService?.enqueueRecompute()
    }

    /// The reminder's "Taken" (the app may be running in the background only).
    func handleSupplementTaken(_ slot: SupplementSlot) async {
        await supplementReminderService?.handleTaken(slot)
    }

    func handleSupplementSnooze(_ slot: SupplementSlot) async {
        await supplementReminderService?.handleSnooze(slot)
    }

    /// Whether supplement reminders are on (Settings, the supplements list); missing means on.
    var supplementRemindersEnabled: Bool {
        ((try? profiles?.setting(SettingKey.supplementRemindersEnabled, as: Bool.self)) ?? nil) ?? true
    }

    /// Turns the supplement reminders on or off; turning them on asks for notification permission. Returns false when
    /// permission was declined (the setting is still saved).
    @discardableResult
    func setSupplementRemindersEnabled(_ enabled: Bool) async -> Bool {
        try? profiles?.setSetting(SettingKey.supplementRemindersEnabled, enabled)
        var allowed = true
        if enabled {
            allowed = await supplementReminder.requestAuthorization()
        }
        refreshSupplementReminders()
        return allowed
    }
}
