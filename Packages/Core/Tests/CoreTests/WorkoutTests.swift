import Foundation
import Testing
@testable import Core

/// A workout on `dayString` from `start` ("18:00") for `minutes`, in Zagreb.
private func workout(
    _ id: String, _ kind: WorkoutKind, _ dayString: String, _ start: String = "18:00", minutes: Double = 60,
    kcal: Double? = nil, km: Double? = nil, source: HealthSource = HealthFixtures.watch,
) -> HealthWorkout {
    let begin = time("\(dayString) \(start)")
    return HealthWorkout(
        id: id, day: day(dayString), activityType: kind.rawValue, start: begin, end: begin.addingTimeInterval(minutes * 60),
        activeKcal: kcal, distanceM: km.map { $0 * 1000 }, source: source,
    )
}

private let gymApp = HealthSource(name: "Gym Log", bundleIdentifier: "com.example.gymlog", productType: "iPhone17,1")

struct WorkoutKindTests {
    @Test func `kinds carry the HealthKit activity type`() {
        #expect(WorkoutKind(activityType: 52) == .walking)
        #expect(WorkoutKind(activityType: 37) == .running)
        #expect(WorkoutKind(activityType: 50) == .strength)
        #expect(WorkoutKind(activityType: 20) == .functionalStrength)
        #expect(WorkoutKind(activityType: 3000) == .other)
    }

    @Test func `retired and unlisted types still have a kind`() {
        #expect(WorkoutKind(activityType: 14) == .dance)
        #expect(WorkoutKind(activityType: 78) == .dance)
        #expect(WorkoutKind(activityType: 30) == .mixedCardio)
        #expect(WorkoutKind(activityType: 2) == .other) // archery
        #expect(WorkoutKind(activityType: 99999) == .other)
    }

    @Test func `every kind has a name of its own`() {
        #expect(Set(WorkoutKind.allCases.map(\.title)).count == WorkoutKind.allCases.count)
        #expect(WorkoutKind.strength.title == "Strength training")
        #expect(WorkoutKind.walking.title == "Walking")
    }

    @Test func `a workout knows its kind and whole minutes`() {
        let run = workout("r", .running, "2026-11-09", minutes: 41.6)
        #expect(run.kind == .running)
        #expect(run.minutes == 42)
        // The duration without pauses is kept when given; never negative.
        let paused = HealthWorkout(
            id: "p", day: day("2026-11-09"), activityType: 37, start: run.start, end: run.end, durationSec: 1800,
            source: HealthFixtures.watch,
        )
        #expect(paused.minutes == 30)
        let backwards = HealthWorkout(
            id: "b", day: day("2026-11-09"), activityType: 37, start: run.end, end: run.start, source: HealthFixtures.watch,
        )
        #expect(backwards.durationSec == 0)
        #expect(backwards.end == backwards.start)
    }
}

struct TrainingRulesTests {
    let monday = day("2026-11-09")

    @Test func `a walk is not training by default`() {
        let rules = TrainingRules.none
        #expect(!rules.countsAsTraining(.walking, on: monday))
        #expect(rules.countsAsTraining(.strength, on: monday))
        #expect(rules.countsAsTraining(.hiking, on: monday))
        #expect(rules.currentExcluded == [.walking])
    }

    @Test func `without a choice no workout decides a training day`() {
        let rules = TrainingRules.none
        #expect(!rules.decidesTrainingDays(on: monday))
        #expect(rules.trainingDays(of: [workout("s", .strength, "2026-11-09")]).isEmpty)
    }

    @Test func `workouts decide training days from the first choice on`() {
        let rules = TrainingRules([monday: [.walking]])
        let workouts = [
            workout("old", .strength, "2026-11-08"), // before the rules started: the day keeps its status
            workout("s", .strength, "2026-11-09"),
            workout("w", .walking, "2026-11-10"),
            workout("r", .running, "2026-11-11"),
        ]
        #expect(rules.trainingDays(of: workouts) == [monday, monday.adding(days: 2)])
        #expect(!rules.decidesTrainingDays(on: monday.previous))
        // Sorting still works before the first choice, with that first choice.
        #expect(rules.countsAsTraining(workouts[0]))
    }

    @Test func `a change applies from its day and earlier days keep theirs`() {
        let rules = TrainingRules([monday: [.walking], monday.adding(days: 7): [.walking, .yoga]])
        #expect(rules.countsAsTraining(.yoga, on: monday.adding(days: 6)))
        #expect(!rules.countsAsTraining(.yoga, on: monday.adding(days: 7)))
        #expect(rules.currentExcluded == [.walking, .yoga])
        let yoga = [workout("a", .yoga, "2026-11-10"), workout("b", .yoga, "2026-11-17")]
        #expect(rules.trainingDays(of: yoga) == [monday.next])
        // Walking can be switched on as well.
        let walker = TrainingRules([monday: []])
        #expect(walker.countsAsTraining(.walking, on: monday))
    }
}

struct WorkoutSessionsTests {
    let rules = TrainingRules.none

    @Test func `one session recorded twice is one workout`() {
        let watch = workout("watch", .strength, "2026-11-09", "18:00", minutes: 60, kcal: 410)
        let app = workout("app", .strength, "2026-11-09", "18:02", minutes: 55, source: gymApp)
        let merged = WorkoutSessions.merged([app, watch], rules: rules)
        #expect(merged.map(\.id) == ["watch"])
        #expect(merged[0].activeKcal == 410)
    }

    @Test func `the double lends what the shown workout lacks`() {
        // The gym app's workout is the training one (the watch recorded a walk at the same time): it is shown, with
        // the watch's energy and distance.
        let watch = workout("watch", .walking, "2026-11-09", "18:00", minutes: 60, kcal: 300, km: 1.2)
        let app = workout("app", .strength, "2026-11-09", "18:00", minutes: 58, source: gymApp)
        let merged = WorkoutSessions.merged([watch, app], rules: rules)
        #expect(merged.map(\.id) == ["app"])
        #expect(merged[0].activeKcal == 300)
        #expect(merged[0].distanceM == 1200)
    }

    @Test func `the watch wins over an app and the longer over the shorter`() {
        let app = workout("app", .strength, "2026-11-09", "18:00", minutes: 70, source: gymApp)
        let watch = workout("watch", .strength, "2026-11-09", "18:00", minutes: 60)
        #expect(WorkoutSessions.merged([app, watch], rules: rules).map(\.id) == ["watch"])
        let short = workout("short", .strength, "2026-11-09", "18:00", minutes: 50)
        #expect(WorkoutSessions.merged([short, watch], rules: rules).map(\.id) == ["watch"])
    }

    @Test func `workouts that follow each other or barely overlap stay apart`() {
        let lift = workout("lift", .strength, "2026-11-09", "18:00", minutes: 60)
        let run = workout("run", .running, "2026-11-09", "19:00", minutes: 30) // starts as the first one ends
        let cooldown = workout("cool", .cooldown, "2026-11-09", "19:25", minutes: 20) // 5 of its 20 minutes overlap the run
        let morning = workout("walk", .walking, "2026-11-09", "07:00", minutes: 30)
        let merged = WorkoutSessions.merged([lift, run, cooldown, morning], rules: rules)
        #expect(merged.map(\.id) == ["walk", "lift", "run", "cool"]) // oldest first
    }

    @Test func `a short workout inside a long one is the same session`() {
        let hike = workout("hike", .hiking, "2026-11-09", "09:00", minutes: 180)
        let walk = workout("walk", .walking, "2026-11-09", "10:00", minutes: 20, source: gymApp)
        #expect(WorkoutSessions.merged([hike, walk], rules: rules).map(\.id) == ["hike"])
    }
}

struct TrainingOverviewTests {
    // 2026-11-11 is a Wednesday; weeks start on Monday (2).
    let today = day("2026-11-11")
    let monday = day("2026-11-09")
    let rules = TrainingRules([LocalDay("2026-08-01")!: [.walking]])

    func overview(_ workouts: [HealthWorkout], training: TrainingDays = .none) -> TrainingOverview {
        TrainingOverview(workouts: workouts, rules: rules, training: training, today: today, firstWeekday: 2)
    }

    @Test func `the week counts training days against the planned ones`() {
        // Planned: Monday, Wednesday, Friday; and Tuesday switched off by hand.
        let training = TrainingDays(
            schedules: [TrainingSchedule(effectiveFrom: day("2026-01-01"), weekdays: [2, 4, 6])],
            overrides: [monday.next: false],
            workoutDays: [monday, monday.next],
        )
        let result = overview([
            workout("mon", .strength, "2026-11-09", minutes: 60),
            workout("tue-1", .running, "2026-11-10", "07:00", minutes: 30),
            workout("tue-2", .strength, "2026-11-10", "18:00", minutes: 45),
            workout("tue-walk", .walking, "2026-11-10", "12:00", minutes: 25, km: 2),
        ], training: training)
        let week = result.week
        #expect(week.start == monday)
        #expect(week.days.count == 7)
        #expect(week.days.map(\.isTrained) == [true, true, false, false, false, false, false])
        #expect(week.days.map(\.isPlanned) == [true, false, true, false, true, false, false])
        #expect(week.trainedDays == 2)
        #expect(week.plannedDays == 3)
        #expect(week.sessions.map(\.id) == ["mon", "tue-1", "tue-2"])
        #expect(week.totalMinutes == 135)
        // The walk is activity, not a session.
        #expect(result.activity.workouts.map(\.id) == ["tue-walk"])
        #expect(result.activity.isOnlyWalks)
        #expect(result.activity.totalMinutes == 25)
        #expect(result.activity.distanceM == 2000)
        #expect(result.hasWorkouts)
    }

    @Test func `weekly sessions cover twelve weeks, oldest first`() {
        let result = overview([
            workout("this", .strength, "2026-11-09"),
            workout("last-1", .strength, "2026-11-02"),
            workout("last-2", .running, "2026-11-08"), // Sunday still belongs to last week
            workout("walk", .walking, "2026-11-03"),
            workout("first", .strength, "2026-08-24"), // the first of the twelve weeks
            workout("before", .strength, "2026-08-23"), // the week before them
        ])
        #expect(result.weeklySessions.count == TrainingOverview.chartWeeks)
        #expect(result.weeklySessions.first?.weekStart == day("2026-08-24"))
        #expect(result.weeklySessions.last?.weekStart == monday)
        #expect(result.weeklySessions.map(\.sessions) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1])
        #expect(TrainingOverview.firstDay(today: today, firstWeekday: 2) == day("2026-08-24"))
        // The first day is inside the 90 days of Health history, whatever the weekday.
        for offset in 0 ..< 7 {
            let someDay = today.adding(days: offset)
            #expect(TrainingOverview.firstDay(today: someDay, firstWeekday: 2).days(until: someDay) < 90)
        }
    }

    @Test func `recent sessions are the last four weeks, newest first, without doubles`() {
        let result = overview([
            workout("old", .strength, "2026-10-14"), // 28 days ago: just outside
            workout("edge", .strength, "2026-10-15"),
            workout("watch", .strength, "2026-11-09", "18:00", minutes: 60),
            workout("app", .strength, "2026-11-09", "18:01", minutes: 58, source: gymApp),
            workout("walk", .walking, "2026-11-10"),
        ])
        #expect(result.recentSessions.map(\.id) == ["watch", "edge"])
        #expect(result.week.sessions.map(\.id) == ["watch"])
    }

    @Test func `other activity is only this week's and names itself by what it holds`() {
        let rules = TrainingRules([day("2026-08-01"): [.walking, .yoga]])
        let result = TrainingOverview(
            workouts: [
                workout("last-week", .walking, "2026-11-08"),
                workout("walk", .walking, "2026-11-09", "07:00", minutes: 30),
                workout("yoga", .yoga, "2026-11-10", minutes: 40),
            ],
            rules: rules, training: .none, today: today, firstWeekday: 2,
        )
        #expect(result.activity.workouts.map(\.id) == ["yoga", "walk"])
        #expect(!result.activity.isOnlyWalks)
        #expect(result.activity.distanceM == nil)
        #expect(result.recentSessions.isEmpty)
        #expect(result.week.trainedDays == 0)
    }

    @Test func `no workouts at all`() {
        let result = overview([])
        #expect(!result.hasWorkouts)
        #expect(result.week.sessions.isEmpty)
        #expect(result.week.totalMinutes == 0)
        #expect(result.weeklySessions.allSatisfy { $0.sessions == 0 })
        #expect(result.activity.workouts.isEmpty)
        #expect(result.activity.isOnlyWalks)
    }

    @Test func `weeks follow the first weekday`() {
        // Sunday-first: Sunday 8 November starts the week of Wednesday the 11th.
        let result = TrainingOverview(
            workouts: [workout("sun", .strength, "2026-11-08")], rules: rules, training: .none, today: today, firstWeekday: 1,
        )
        #expect(result.week.start == day("2026-11-08"))
        #expect(result.week.trainedDays == 1)
    }
}
