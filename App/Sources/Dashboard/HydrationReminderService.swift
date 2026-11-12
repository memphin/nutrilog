import Core
import Foundation
import Persistence

/// Keeps the one hydration reminder in line with today's drinks (spec §4): plans it with
/// `HydrationReminder.next(day:tomorrowWake:)` on the same `HydrationDay` the Today tile shows
/// (`HydrationDayBuilder`, `HydrationGoalResolver`), and schedules or cancels it.
///
/// Recomputes when today's drinks, today's Health row (other apps' water, wake-up time, weight trend), the weigh-ins,
/// the profile (goal) or the training days (a training day's boost) change while `start()`ed; `AppEnvironment` also
/// asks after launch, foreground, imports, day changes and settings changes, which nothing here observes. Cancels when
/// reminders are off or notifications are not allowed.
@MainActor
final class HydrationReminderService {
    /// The last reminder scheduled and the stretch without a drink it is about (the day and its last drink). Kept
    /// (in `UserDefaults` when given) so a reminder that is due — the plan never lies in the past — is not fired again
    /// by every later recompute or relaunch once it has fired; a new drink starts a new stretch.
    private struct Scheduled: Codable, Equatable {
        var day: String
        var lastDrinkAt: Date?
        var date: Date
    }

    private static let scheduledKey = "hydrationReminder.lastScheduled"

    private let hydration: HydrationRepository
    private let metrics: DailyMetricsRepository
    private let profiles: ProfileRepository
    private let water: WaterRepository
    private let weights: WeightRepository
    private let trainingDays: TrainingDayRepository
    private let scheduler: any HydrationReminderScheduling
    private let clock: AppClock
    private let calendar: Calendar
    private let locale: Locale
    private let defaults: UserDefaults?

    private var lastScheduled: Scheduled?
    private var observation: Task<Void, Never>?
    private var observedDay: LocalDay?
    /// The last recompute queued: recomputes run one at a time, in order, so the newest data has the last word.
    private var pending: Task<Void, Never>?

    /// `defaults` remembers the last plan across launches; nil keeps it in memory (tests, previews).
    init(
        hydration: HydrationRepository,
        metrics: DailyMetricsRepository,
        profiles: ProfileRepository,
        water: WaterRepository,
        weights: WeightRepository,
        trainingDays: TrainingDayRepository,
        scheduler: any HydrationReminderScheduling,
        clock: AppClock,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        defaults: UserDefaults? = nil,
    ) {
        self.hydration = hydration
        self.metrics = metrics
        self.profiles = profiles
        self.water = water
        self.weights = weights
        self.trainingDays = trainingDays
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
        self.locale = locale
        self.defaults = defaults
        lastScheduled = defaults?.data(forKey: Self.scheduledKey).flatMap { try? JSONDecoder().decode(Scheduled.self, from: $0) }
    }

    deinit {
        observation?.cancel()
    }

    /// The amount the notification's action logs: the smallest quick-add size.
    var addActionMl: Int {
        WaterQuickAdd.sizes(from: profiles).first ?? WaterQuickAdd.defaultSizes[0]
    }

    // MARK: Observing

    /// Recomputes whenever today's drinks, Health row, weigh-ins, profile or training days change. Tomorrow's drinks
    /// and Health row are watched too: a suspended app that wakes up after midnight for a Health sync sees the new
    /// day's row (its wake-up time) written, and the recompute then moves the observation to the new day. Call again
    /// after the day changed: it then observes the new day (and recomputes for it); otherwise it does nothing.
    func start() {
        let day = LocalDay(clock.now(), calendar: calendar)
        guard observation == nil || observedDay != day else { return }
        observation?.cancel()
        observedDay = day
        let hydration = hydration
        let metrics = metrics
        let profiles = profiles
        let weights = weights
        let trainingDays = trainingDays
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.enqueueRecompute() }
        observation = Task {
            await withDiscardingTaskGroup { group in
                group.addTask { await Self.follow({ hydration.observeIntakes(in: day ... day.next) }, changed: changed) }
                group.addTask { await Self.follow({ metrics.observeMetrics(in: day ... day.next) }, changed: changed) }
                group.addTask { await Self.follow({ profiles.observeProfile() }, changed: changed) }
                group.addTask { await Self.follow({ weights.observeAllEntries() }, changed: changed) }
                group.addTask { await Self.follow({ trainingDays.observeTrainingDays(in: day ... day.next) }, changed: changed) }
            }
        }
    }

    /// Calls `changed` for every value of the observation (the first one too), resubscribing after errors.
    private static func follow(
        _ makeSequence: @escaping @Sendable () -> some AsyncSequence, changed: @escaping @MainActor @Sendable () -> Void,
    ) async {
        await DiaryModel.resubscribing(makeSequence) { _ in changed() } onError: { _ in }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        observedDay = nil
    }

    // MARK: Recomputing

    /// Plans the reminder from what is stored now and schedules or cancels it. Returns when done.
    func recompute() async {
        await enqueueRecompute().value
    }

    /// The notification's "+ 250 ml": logs the smallest quick-add size of water now, then plans the next reminder.
    func handleAddAction() async {
        let now = clock.now()
        // A failed write has nothing to report to: the notification is gone. The plan then stays as it was.
        _ = try? water.add(ml: Double(addActionMl), day: LocalDay(now, calendar: calendar))
        await recompute()
    }

    /// Queues a recompute after the ones already queued.
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
            start() // past midnight: observe the new day
        }
        guard HydrationSettings.load(from: profiles).remindersEnabled, await scheduler.isAuthorized() else {
            await cancel()
            return
        }
        // Read after the permission check, which may take a moment: the plan uses the newest data.
        guard let plan = makePlan() else { return } // unreadable data: leave the reminder as it is
        guard let reminder = plan.reminder else {
            await cancel()
            return
        }
        let now = clock.now()
        let scheduled = Scheduled(day: plan.day.isoString, lastDrinkAt: plan.lastDrinkAt, date: reminder.date)
        if reminder.date <= now, let lastScheduled, lastScheduled.date <= now, lastScheduled.day == scheduled.day,
           lastScheduled.lastDrinkAt == scheduled.lastDrinkAt
        {
            return // already fired for this stretch without a drink
        }
        do {
            try await scheduler.schedule(
                at: reminder.date, title: plan.title, body: plan.body,
                actionTitle: HydrationReminderCopy.actionTitle(ml: addActionMl),
            )
            remember(scheduled)
        } catch {
            // Not scheduled (permission withdrawn meanwhile): the next recompute tries again.
        }
    }

    private func cancel() async {
        await scheduler.cancel()
        remember(nil)
    }

    private func remember(_ scheduled: Scheduled?) {
        lastScheduled = scheduled
        guard let defaults else { return }
        if let scheduled, let data = try? JSONEncoder().encode(scheduled) {
            defaults.set(data, forKey: Self.scheduledKey)
        } else {
            defaults.removeObject(forKey: Self.scheduledKey)
        }
    }

    /// Today's hydration and the reminder it leads to, with the texts; nil when the data can't be read.
    private func makePlan() -> Plan? {
        let now = clock.now()
        let today = LocalDay(now, calendar: calendar)
        let settings = HydrationSettings.load(from: profiles)
        do {
            let intakes = try hydration.intakes(in: today ... today)[today] ?? []
            let record = try metrics.metrics(on: today)
            let profile = try profiles.profile()
            let trends = HydrationGoalResolver.trendsKg(in: today ... today.next, metrics: metrics, weights: weights, calendar: calendar)
            let training = try trainingDays.trainingDays(in: today ... today.next)
            let goalMl = HydrationGoalResolver.goalMl(on: today, profile: profile, trendKg: trends[today], training: training)
            let day = HydrationDayBuilder.make(
                day: today, intakes: intakes, otherAppsMl: record?.waterMl ?? 0, wokeAt: record?.wokeAt,
                settings: settings, goalMl: goalMl, now: now, calendar: calendar,
            )
            let tomorrowWake = settings.wake(on: today.next, wokeAt: nil, calendar: calendar)
            guard let reminder = HydrationReminder.next(day: day, tomorrowWake: tomorrowWake) else {
                return Plan(reminder: nil, day: today, lastDrinkAt: day.lastIntakeAt)
            }
            // A reminder planned for tomorrow speaks of tomorrow: nothing drunk yet, tomorrow's goal.
            let isTomorrow = LocalDay(reminder.date, calendar: calendar) != today
            let totalMl = isTomorrow ? 0 : day.totalMl
            let planGoalMl = isTomorrow
                ? HydrationGoalResolver.goalMl(on: today.next, profile: profile, trendKg: trends[today.next], training: training)
                : goalMl
            return Plan(
                reminder: reminder,
                title: HydrationReminderCopy.title(reminder.reason),
                body: HydrationReminderCopy.body(
                    reminder.reason, totalMl: totalMl, goalMl: planGoalMl, calendar: calendar, locale: locale,
                ),
                day: isTomorrow ? today.next : today,
                lastDrinkAt: isTomorrow ? nil : day.lastIntakeAt,
            )
        } catch {
            return nil
        }
    }

    /// The reminder planned from the stored data, with its texts and the stretch without a drink it is about.
    private struct Plan {
        /// nil when the goal is reached.
        var reminder: HydrationReminder.Plan?
        var title = ""
        var body = ""
        /// The day the reminder speaks of and its last drink so far.
        var day: LocalDay
        var lastDrinkAt: Date?
    }
}

// MARK: - App

extension HydrationReminderService {
    /// The service on the app's database.
    convenience init(database: AppDatabase, scheduler: any HydrationReminderScheduling, clock: AppClock, defaults: UserDefaults?) {
        self.init(
            hydration: HydrationRepository(database),
            metrics: DailyMetricsRepository(database, clock: clock),
            profiles: ProfileRepository(database, clock: clock),
            water: WaterRepository(database, clock: clock),
            weights: WeightRepository(database, clock: clock),
            trainingDays: TrainingDayRepository(database, clock: clock),
            scheduler: scheduler,
            clock: clock,
            defaults: defaults,
        )
    }
}

extension AppEnvironment {
    /// At launch: registers the notification's add-water action and starts following today's drinks.
    func startHydrationReminders() {
        guard let hydrationReminderService else { return }
        LocalNotificationHydrationReminder.registerCategory(
            actionTitle: HydrationReminderCopy.actionTitle(ml: hydrationReminderService.addActionMl),
        )
        hydrationReminderService.start()
    }

    /// Plans the hydration reminder again (and follows the new day after midnight): after settings changes, imports,
    /// Health syncs and coming back to the foreground. Never asks for notification permission.
    func refreshHydrationReminder() {
        hydrationReminderService?.start()
        hydrationReminderService?.enqueueRecompute()
    }

    /// The reminder's "+ 250 ml" action (the app may be running in the background only): logs the water and plans the
    /// next reminder, then writes the water to Health and refreshes the widgets before returning.
    func handleHydrationAddAction() async {
        await hydrationReminderService?.handleAddAction()
        await healthWrites?.drain()
        widgetDataDidChange()
    }
}
