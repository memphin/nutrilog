import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

/// The Training tab: workouts from Apple Health sorted into training and everyday activity, training days that follow
/// them, and this week's fuel.
@MainActor
struct TrainingTabTests {
    // `ManualClock` starts on Monday 2026-11-09 at noon.
    let clock = ManualClock()
    let monday = LocalDay("2026-11-09")!
    let watch = FakeHealthDataSource.demoWatch

    func workout(
        _ id: String,
        _ kind: WorkoutKind,
        _ day: LocalDay,
        hour: Int = 9,
        minutes: Double = 60,
        kcal: Double? = nil,
        km: Double? = nil,
    )
        -> HealthWorkout
    {
        let start = day.date(atHour: hour)
        return HealthWorkout(
            id: id, day: day, activityType: kind.rawValue, start: start, end: start.addingTimeInterval(minutes * 60),
            activeKcal: kcal, distanceM: km.map { $0 * 1000 }, source: watch,
        )
    }

    /// An app connected to a fake Health with these workouts, synced.
    func environment(_ workouts: [HealthWorkout]) async throws -> (AppEnvironment, FakeHealthDataSource) {
        var state = FakeHealthDataSource.State()
        state.workouts = workouts
        let fake = FakeHealthDataSource(state: state)
        let env = AppEnvironment.preview(clock: clock.appClock, health: fake)
        try await env.connectHealth()
        await env.healthSync?.waitForSync()
        return (env, fake)
    }

    /// A model whose observations have delivered.
    func model(_ env: AppEnvironment) async throws -> (TrainingModel, Task<Void, Never>) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let model = TrainingModel(environment: env) { calendar }
        let task = Task { await model.observe() }
        #expect(await waitUntil { model.overview != nil })
        return (model, task)
    }

    // MARK: Sync and training days

    @Test func `a sync stores the workouts and a training workout makes today a training day`() async throws {
        let (env, _) = try await environment([
            workout("lift", .strength, monday, kcal: 410),
            workout("walk", .walking, monday.previous, km: 3),
            workout("old", .strength, monday.adding(days: -3)),
            workout("ancient", .running, monday.adding(days: -120)), // outside the 90 days read
        ])
        let stored = try #require(try env.workouts?.workouts(in: monday.adding(days: -200) ... monday))
        #expect(stored.map(\.id) == ["old", "walk", "lift"])
        // The rules started today: today's training counts, the one three days ago leaves its day as it was.
        #expect(try env.workouts?.rules() == TrainingRules([monday: [.walking]]))
        let days = try #require(try env.trainingDays?.trainingDays(in: monday.adding(days: -7) ... monday))
        #expect(days.workoutDays == [monday])
        #expect(days.isTraining(monday))
        #expect(!days.isTraining(monday.adding(days: -3)))
    }

    @Test func `without workouts nothing starts and no day changes`() async throws {
        let (env, _) = try await environment([])
        #expect(try env.workouts?.rules() == TrainingRules.none)
        #expect(try env.trainingDays?.trainingDays(in: monday ... monday) == TrainingDays.none)
    }

    @Test func `today's target is boosted by a training workout and the switch still wins`() async throws {
        let (env, _) = try await environment([workout("lift", .strength, monday)])
        let profiles = try #require(env.profiles), training = try #require(env.trainingDays)
        try profiles.setTarget(Target(
            effectiveFrom: monday.adding(days: -30), kcal: 2000, macros: MacroTargets(proteinG: 150, carbsG: 200, fatG: 70),
            origin: .manual,
        ))
        #expect(try training.effectiveTarget(on: monday)?.kcal == 2200)
        #expect(env.toggleTrainingDay(monday) == nil) // switched off by hand
        #expect(try training.effectiveTarget(on: monday)?.kcal == 2000)
        // The next sync doesn't bring it back.
        await env.healthSync?.refresh(force: true)
        #expect(try training.effectiveTarget(on: monday)?.kcal == 2000)
    }

    @Test func `a workout deleted in Health disappears with the next sync`() async throws {
        let (env, fake) = try await environment([workout("lift", .strength, monday), workout("run", .running, monday, hour: 7)])
        fake.update { $0.workouts.removeAll { $0.id == "lift" } }
        await env.healthSync?.refresh(force: true)
        #expect(try env.workouts?.workouts(in: monday ... monday).map(\.id) == ["run"])
    }

    // MARK: The tab

    @Test func `the overview sorts training from walks and counts the week`() async throws {
        let (env, _) = try await environment([
            workout("lift", .strength, monday, hour: 9, minutes: 60, kcal: 410),
            workout("lift-app", .strength, monday, hour: 9, minutes: 58), // the same session from another app
            workout("walk", .walking, monday, hour: 7, minutes: 30, km: 2.4),
            workout("run", .running, monday.adding(days: -2), minutes: 42, kcal: 480, km: 6.8),
        ])
        try env.trainingDays?.setSchedule(weekdays: [2, 4, 6], boostPercent: 10, effectiveFrom: monday.adding(days: -30))
        let (model, task) = try await model(env)
        defer { task.cancel() }
        #expect(model.access == .connected)
        #expect(await waitUntil { model.overview?.week.plannedDays == 3 })
        let overview = try #require(model.overview)
        #expect(overview.hasWorkouts)
        #expect(overview.week.start == monday)
        #expect(overview.week.sessions.map(\.id) == ["lift"])
        #expect(overview.week.trainedDays == 1)
        #expect(overview.recentSessions.map(\.id) == ["lift", "run"])
        #expect(overview.weeklySessions.suffix(2).map(\.sessions) == [1, 1])
        #expect(overview.activity.workouts.map(\.id) == ["walk"])
        #expect(TrainingText.weekHeadline(overview.week) == "1 of 3 planned · 1 h")
        #expect(TrainingText.activitySummary(overview.activity) == "1 this week · 30 min · \(TrainingText.km(2400))")
    }

    @Test func `the overview follows a new sync and a change of what counts as training`() async throws {
        let (env, fake) = try await environment([workout("walk", .walking, monday, km: 3)])
        let (model, task) = try await model(env)
        defer { task.cancel() }
        #expect(model.overview?.week.sessions.isEmpty == true)
        #expect(model.overview?.activity.workouts.count == 1)

        fake.update { $0.workouts.append(workout("lift", .strength, monday, hour: 10)) }
        await env.healthSync?.refresh(force: true)
        #expect(await waitUntil { model.overview?.week.sessions.map(\.id) == ["lift"] })

        // Walking counts as training from today on.
        try env.workouts?.setExcluded([], from: monday)
        #expect(await waitUntil { model.overview?.week.sessions.count == 2 })
        #expect(model.overview?.activity.workouts.isEmpty == true)
    }

    @Test func `access says what the tab can show`() async throws {
        let unavailable = AppEnvironment.preview(health: FakeHealthDataSource(isAvailable: false))
        #expect(TrainingModel(environment: unavailable).access == .unavailable)

        let fake = FakeHealthDataSource()
        let env = AppEnvironment.preview(clock: clock.appClock, health: fake)
        let model = TrainingModel(environment: env)
        await env.healthSync?.reloadAuthorization()
        #expect(model.access == .notConnected)

        try await env.connectHealth()
        await env.healthSync?.waitForSync()
        #expect(model.access == .connected)

        // An update added a type (workouts): Health would ask again, the user is still connected.
        fake.update { $0.authorizationRequested = false }
        await env.healthSync?.reloadAuthorization()
        #expect(model.access == .needsWorkoutAccess)

        fake.update { $0.workouts = [workout("lift", .strength, monday)] }
        await model.allowWorkouts()
        await env.healthSync?.waitForSync()
        #expect(model.errorMessage == nil)
        #expect(model.access == .connected)
        #expect(fake.snapshot.authorizationRequestCount == 2)
        #expect(try env.workouts?.workouts(in: monday ... monday).map(\.id) == ["lift"])
    }

    @Test func `the demo data fills the tab`() async throws {
        let env = AppEnvironment.preview(sampleData: true, clock: clock.appClock)
        await env.healthSync?.refresh()
        let (model, task) = try await model(env)
        defer { task.cancel() }
        let overview = try #require(model.overview)
        // Monday: strength, recorded by the watch and a gym app — one session.
        #expect(overview.week.sessions.map(\.kind) == [.strength])
        #expect(overview.week.sessions.first?.source.kind == .appleWatch)
        #expect(overview.weeklySessions.count == 12)
        #expect(overview.weeklySessions.dropLast().allSatisfy { $0.sessions == 4 }) // three strength days and a run
        #expect(overview.recentSessions.count == 16)
        #expect(overview.activity.workouts.isEmpty) // no walk yet this week

        let settings = HealthSettingsModel()
        await settings.load(environment: env)
        #expect(settings.statuses[.workout] != .noData)
    }

    // MARK: Fuel

    @Test func `fuel shows last days' intake, protein per kg and the weight trend`() throws {
        // Two logged days (Monday, Tuesday) with a weight trend; the rest of the week is empty.
        let eaten = Nutrients(kcal: 2300, proteinG: 160, carbsG: 250, fatG: 70)
        var stats: [DayStats] = []
        for offset in 0 ..< 7 {
            var stat = DayStats(day: monday.adding(days: offset), targetKcal: 2400)
            if offset < 2 {
                stat.intake = eaten
                stat.entryCount = 3
                stat.trendKg = 80 - 0.1 * Double(offset)
            }
            stats.append(stat)
        }
        let fuel = TrainingFuel(report: WeeklyReport(days: stats, trendBefore: 80.2), weightKg: 85)
        #expect(fuel.averageKcal == 2300)
        #expect(fuel.averageTargetKcal == 2400)
        #expect(fuel.proteinG == 160)
        #expect(try abs(#require(fuel.proteinPerKg) - 160 / 79.9) < 0.0001) // the week's own trend, not the fallback
        #expect(try abs(#require(fuel.trendChangeKg) + 0.3) < 0.0001)

        // Nothing logged: no numbers; no weight at all: no protein per kg.
        let empty = TrainingFuel(report: WeeklyReport(days: [DayStats(day: monday)]), weightKg: 80)
        #expect(empty.averageKcal == nil && empty.proteinPerKg == nil && empty.trendChangeKg == nil)
        let noWeight = TrainingFuel(
            report: WeeklyReport(days: [DayStats(
                day: monday,
                intake: Nutrients(kcal: 2000, proteinG: 150, carbsG: 200, fatG: 70),
                entryCount: 3,
            )]),
            weightKg: nil,
        )
        #expect(noWeight.proteinG == 150 && noWeight.proteinPerKg == nil)
        // Without a trend in the week the latest known weight is used.
        let fallback = TrainingFuel(
            report: WeeklyReport(days: [DayStats(
                day: monday,
                intake: Nutrients(kcal: 2000, proteinG: 150, carbsG: 200, fatG: 70),
                entryCount: 3,
            )]),
            weightKg: 75,
        )
        #expect(fallback.proteinPerKg == 2)
    }

    @Test func `the model loads this week's fuel from the diary`() throws {
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = TrainingModel(environment: env)
        model.reloadFuel()
        #expect(model.fuel?.averageKcal == nil)
        // Today counts once it is marked as fully logged.
        let diary = try #require(env.diary)
        for slot in ["breakfast", "lunch", "dinner"] {
            try diary.logQuickAdd(name: nil, nutrients: Nutrients(kcal: 700, proteinG: 50, carbsG: 80, fatG: 20), slotID: slot, day: monday)
        }
        try diary.setDayNote(day: monday, text: "", isComplete: true)
        model.reloadFuel()
        #expect(model.fuel?.averageKcal == 2100)
        #expect(model.fuel?.proteinG == 150)
    }

    // MARK: Texts

    @Test func `texts of the week, a workout and distances`() {
        let english = Locale(identifier: "en_US")
        let lift = workout("lift", .strength, monday, minutes: 58, kcal: 410.4)
        let run = workout("run", .running, monday.next, minutes: 42, kcal: 480, km: 6.84)
        let plain = workout("yoga", .yoga, monday, minutes: 30)
        #expect(TrainingText.extras(lift, unit: .kcal) == "410 kcal")
        #expect(TrainingText.extras(run, unit: .kcal) == "480 kcal · \(TrainingText.km(6840))")
        #expect(TrainingText.extras(plain, unit: .kcal) == nil)
        #expect(TrainingText.km(6840, locale: english) == "6.8 km")
        #expect(TrainingText.km(13200, locale: Locale(identifier: "hr_HR")) == "13,2 km")
        #expect(TrainingText.gramsPerKg(1.72, locale: english) == "1.7 g/kg")

        let days = (0 ..< 7).map { offset in
            TrainingWeek.Day(day: monday.adding(days: offset), sessions: offset == 0 ? [lift] : offset == 1 ? [run] : [], isPlanned: false)
        }
        let week = TrainingWeek(days: days)
        #expect(TrainingText.weekHeadline(week) == "2 workouts · 1 h 40 min")
        #expect(TrainingText.weekSpoken(week).hasPrefix("2 workouts · 1 h 40 min, trained on "))
        let none = TrainingWeek(days: days.map { TrainingWeek.Day(day: $0.day, sessions: [], isPlanned: $0.day == monday) })
        #expect(TrainingText.weekHeadline(none) == "0 of 1 planned")
        #expect(TrainingText.weekSpoken(none) == "0 of 1 planned")
        let one = TrainingWeek(days: [TrainingWeek.Day(day: monday, sessions: [plain], isPlanned: false)])
        #expect(TrainingText.weekHeadline(one) == "1 workout · 30 min")

        #expect(TrainingText.axisStep(top: 1) == 1)
        #expect(TrainingText.axisStep(top: 4) == 1)
        #expect(TrainingText.axisStep(top: 5) == 2)
        #expect(TrainingText.axisStep(top: 14) == 4)
    }

    @Test func `every workout kind has an icon`() {
        #expect(WorkoutKind.allCases.allSatisfy { !$0.systemImage.isEmpty })
        #expect(WorkoutKind.walking.systemImage == "figure.walk")
    }

    // MARK: Settings

    @Test func `settings list the kinds found, walking and whatever is switched off`() {
        #expect(TrainingDaysSettingsView.kinds(found: [], excluded: [.walking]) == [.walking])
        #expect(TrainingDaysSettingsView.kinds(found: [.strength, .running], excluded: [.walking, .yoga])
            == [.running, .strength, .walking, .yoga])
    }

    @Test func `croatian has the tab's texts`() throws {
        let path = try #require(Bundle.main.path(forResource: "hr", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let croatian = Locale(identifier: "hr_HR")
        func workouts(_ count: Int) -> String {
            String(localized: "\(count) workouts", bundle: bundle, locale: croatian)
        }
        #expect(workouts(1) == "1 trening")
        #expect(workouts(3) == "3 treninga")
        #expect(workouts(5) == "5 treninga")
        let done = 3
        let planned = 4
        #expect(String(localized: "\(done) of \(planned) planned", bundle: bundle, locale: croatian) == "3 od 4 po planu")
        #expect(String(localized: "Walks", bundle: bundle, locale: croatian) == "Šetnje")
    }
}
