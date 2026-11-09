import Core
import Foundation

public extension FakeHealthDataSource {
    static let demoWatch = HealthSource(name: "Apple Watch", bundleIdentifier: "com.apple.health.demo-watch", productType: "Watch7,1")
    static let demoPhone = HealthSource(name: "iPhone", bundleIdentifier: "com.apple.health.demo-phone", productType: "iPhone17,1")
    static let demoScale = HealthSource(name: "Withings", bundleIdentifier: "com.withings.wiScaleNG", productType: "iPhone17,1")

    /// An already-authorized fake with plausible, deterministic data for the `days` days ending on `lastDay`:
    /// a Withings weigh-in with body fat each morning (slowly trending down), Apple Watch steps, energy, sleep
    /// with stages, resting heart rate and overnight HRV, and water. For previews and screenshots.
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
        }
        return FakeHealthDataSource(state: state)
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
