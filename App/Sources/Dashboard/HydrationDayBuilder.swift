import Core
import Foundation

/// The one place a day's `HydrationDay` is put together from what the app stores: the Today tile and detail
/// (`DashboardModel.hydrationDay(at:)`) and the reminders use it, so they always agree.
enum HydrationDayBuilder {
    /// `day`'s hydration at `now`. One parameter per stored value it is built from, hence the parameter count: a
    /// wrapper type would only rename them.
    ///
    /// - Parameters:
    ///   - intakes: the day's drinks logged in Vitalion.
    ///   - otherAppsMl: water other apps wrote to Apple Health that day (`daily_metrics.water_ml`, untimed).
    ///   - wokeAt: when Apple Health says the user woke up (`daily_metrics.woke_at`); the settings' fallback
    ///     wake-up time is used when it is nil or not on `day`.
    ///   - goalMl: the day's goal (`HydrationGoalResolver`).
    static func make( // swiftlint:disable:this function_parameter_count
        day: LocalDay,
        intakes: [FluidIntake],
        otherAppsMl: Double,
        wokeAt: Date?,
        settings: HydrationSettings,
        goalMl: Double,
        now: Date,
        calendar: Calendar,
    ) -> HydrationDay {
        HydrationDay(
            intakes: intakes,
            otherAppsMl: otherAppsMl,
            goalMl: goalMl,
            wake: settings.wake(on: day, wokeAt: wokeAt, calendar: calendar),
            bedtime: settings.bedtime(on: day, calendar: calendar),
            gapThreshold: settings.gapThreshold,
            behindMarginMl: settings.behindMarginMl,
            now: now,
        )
    }
}
