import Core
import Foundation

public extension FakeHealthDataSource {
    static let demoWatch = HealthSource(name: "Apple Watch", bundleIdentifier: "com.apple.health.demo-watch", productType: "Watch7,1")
    static let demoPhone = HealthSource(name: "iPhone", bundleIdentifier: "com.apple.health.demo-phone", productType: "iPhone17,1")
    static let demoScale = HealthSource(name: "Withings", bundleIdentifier: "com.withings.wiScaleNG", productType: "iPhone17,1")
    static let demoGymApp = HealthSource(name: "Gym Log", bundleIdentifier: "com.example.gymlog", productType: "iPhone17,1")

    /// An already-authorized fake with plausible, deterministic data for the `days` days ending on `lastDay`:
    /// a Withings weigh-in with body fat each morning (slowly trending down), Apple Watch steps, energy, sleep
    /// with stages, resting heart rate and overnight HRV, water, and workouts (strength three times a week — also
    /// recorded by a gym app — a Saturday run and a walk on the other days). For previews and screenshots.
    static func demo(endingOn lastDay: LocalDay, days: Int = 120, calendar: Calendar = .current) -> FakeHealthDataSource {
        var state = State()
        state.authorizationRequested = true
        state.characteristics = HealthCharacteristics(heightCm: 181, dateOfBirth: LocalDay(year: 1988, month: 5, day: 14), sex: .male)

        for offset in 0 ..< max(days, 0) {
            let day = lastDay.adding(days: -offset)
            let at = { (hour: Int, minute: Int) in
                day.date(atHour: hour, calendar: calendar).addingTimeInterval(TimeInterval(minute * 60))
            }
            // A smooth, repeatable wobble in [-1, 1] instead of randomness.
            let wobble = sin(Double(offset) * 1.7)
            let nightStart = day.previous.date(atHour: 23, calendar: calendar).addingTimeInterval(wobble * 1200)

            state.cumulativeSamples[.steps, default: []].append(
                HealthQuantitySample(start: at(12, 0), value: (8500 + 3000 * wobble).rounded(), source: demoWatch),
            )
            state.cumulativeSamples[.activeEnergy, default: []].append(
                HealthQuantitySample(start: at(12, 0), value: (480 + 150 * wobble).rounded(), source: demoWatch),
            )
            state.cumulativeSamples[.basalEnergy, default: []].append(
                HealthQuantitySample(start: at(12, 0), value: 1750, source: demoWatch),
            )
            state.cumulativeSamples[.dietaryWater, default: []].append(
                HealthQuantitySample(start: at(15, 0), value: 1500 + 250 * (wobble + 1).rounded(), source: demoPhone),
            )

            let weight = 82 + Double(offset) * 0.02 + 0.4 * wobble
            state.samples[.bodyMass, default: []].append(HealthQuantitySample(start: at(7, 5), value: weight, source: demoScale))
            state.samples[.bodyFatPercentage, default: []].append(
                HealthQuantitySample(start: at(7, 5), value: 18 + Double(offset) * 0.01, source: demoScale),
            )
            state.samples[.restingHeartRate, default: []].append(
                HealthQuantitySample(start: at(20, 0), value: (54 + 3 * wobble).rounded(), source: demoWatch),
            )
            for hour in [1, 3, 5] {
                state.samples[.heartRateVariabilitySDNN, default: []].append(
                    HealthQuantitySample(start: at(hour, 10), value: 45 + 8 * wobble + Double(hour), source: demoWatch),
                )
            }

            state.sleep += demoNight(startingAt: nightStart)
            state.workouts += demoWorkouts(on: day, wobble: wobble, calendar: calendar)
        }
        return FakeHealthDataSource(state: state)
    }

    /// Monday, Wednesday and Friday: an hour of strength training, recorded by the watch and by a gym app (one
    /// session). Saturday: a run. The other days: a walk.
    private static func demoWorkouts(on day: LocalDay, wobble: Double, calendar: Calendar) -> [HealthWorkout] {
        let evening = day.date(atHour: 18, calendar: calendar)
        func workout(
            _ suffix: String, _ kind: WorkoutKind, minutes: Double, kcal: Double?, km: Double? = nil, source: HealthSource = demoWatch,
            startOffsetMin: Double = 0,
        ) -> HealthWorkout {
            let start = evening.addingTimeInterval(startOffsetMin * 60)
            return HealthWorkout(
                id: "demo-\(day.isoString)-\(suffix)", day: day, activityType: kind.rawValue, start: start,
                end: start.addingTimeInterval(minutes * 60), activeKcal: kcal, distanceM: km.map { $0 * 1000 }, source: source,
            )
        }
        switch day.weekday {
        case 2, 4, 6:
            let minutes = (58 + 6 * wobble).rounded()
            return [
                workout("strength", .strength, minutes: minutes, kcal: (400 + 40 * wobble).rounded()),
                workout("gymlog", .strength, minutes: minutes - 4, kcal: nil, source: demoGymApp, startOffsetMin: 2),
            ]
        case 7:
            return [workout("run", .running, minutes: (42 + 4 * wobble).rounded(), kcal: 480, km: 6.8 + 0.6 * wobble)]
        default:
            return [workout("walk", .walking, minutes: (38 + 8 * wobble).rounded(), kcal: 150, km: 3.1 + 0.5 * wobble)]
        }
    }

    /// About 7 h 20 min asleep in 90-minute cycles with one short awakening.
    private static func demoNight(startingAt start: Date) -> [SleepSample] {
        let pattern: [(SleepStage, Double)] = [
            (.asleepCore, 25), (.asleepDeep, 45), (.asleepCore, 30), (.asleepREM, 20),
            (.asleepCore, 40), (.asleepDeep, 30), (.asleepREM, 25), (.awake, 10),
            (.asleepCore, 50), (.asleepREM, 30), (.asleepCore, 60), (.asleepREM, 35), (.asleepCore, 30),
        ]
        var samples: [SleepSample] = []
        var cursor = start
        for (stage, minutes) in pattern {
            let end = cursor.addingTimeInterval(minutes * 60)
            samples.append(SleepSample(start: cursor, end: end, stage: stage, source: demoWatch))
            cursor = end
        }
        return samples
    }
}
