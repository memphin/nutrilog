import Core
import DesignSystem
import Foundation
import SwiftUI

// Streaks: days in a row the step, sleep and hydration goals were reached, shown as a small badge on those tiles.
// Past days are measured against today's step and sleep goals (those have no history); hydration uses each day's own
// goal (`DashboardData.hydrationGoalMl(on:)`), boosted when that day was a training day.

extension DashboardSnapshot {
    /// The tile's streak; nil for tiles without a daily goal.
    func streak(for tile: DashboardTile) -> Streak? {
        streaks[tile]
    }

    static func streaks(data: DashboardData, rows: [DailyHealthMetrics]) -> [DashboardTile: Streak] {
        let metrics = Dictionary(rows.map { ($0.day, $0) }) { first, _ in first }
        // Like the tile, sparkline and history: every drink logged in Vitalion plus other apps' water.
        let otherAppsMl = Dictionary(rows.compactMap { row in row.waterMl.map { (row.day, $0) } }, uniquingKeysWith: +)
        let hydrationMl = HydrationTotals.byDay(intakes: data.hydrationIntakes, otherAppsMl: otherAppsMl)
        func streak(todayIsFinal: Bool = false, _ reached: (LocalDay) -> Bool) -> Streak {
            Streak.current(today: data.today, maxDays: DashboardData.historyDays, todayIsFinal: todayIsFinal, reached: reached)
        }
        // Like the tile: time asleep, or time in bed when that is all Health has.
        func sleepMinutes(_ day: LocalDay) -> Int? {
            metrics[day].flatMap { $0.sleepAsleepMin ?? $0.sleepInBedMin }
        }
        return [
            .steps: streak { day in
                guard let steps = metrics[day]?.steps else { return false }
                return StepGoal.band(steps: Double(steps), goal: data.stepGoal) == .reached
            },
            // Today's sleep is last night's, final once recorded: a short night ends the streak this morning.
            .sleep: streak(todayIsFinal: sleepMinutes(data.today) != nil) { day in
                guard let minutes = sleepMinutes(day) else { return false }
                return SleepGoal.band(minutes: Double(minutes), goal: data.sleepGoalMin) == .reached
            },
            // That day's total against that day's goal.
            .water: streak { day in
                let goal = data.hydrationGoalMl(on: day)
                return goal > 0 && (hydrationMl[day] ?? 0) >= goal
            },
        ]
    }
}

/// The bolt and day count in a tile's header; nothing when there is no streak.
struct StreakBadge: View {
    let streak: Streak

    /// "5", "60+".
    nonisolated static func text(_ streak: Streak) -> String {
        streak.isAtLimit ? "\(streak.days)+" : "\(streak.days)"
    }

    /// "5-day streak", "60-day streak or more"; nil without a streak.
    nonisolated static func spoken(_ streak: Streak, locale: Locale = .current) -> String? {
        let days = streak.days
        guard days > 0 else { return nil }
        return streak.isAtLimit
            ? String(localized: "\(days)-day streak or more", locale: locale)
            : String(localized: "\(days)-day streak", locale: locale)
    }

    var body: some View {
        if streak.days > 0 {
            // Green once today counts too; secondary while today is still open.
            Label(Self.text(streak), systemImage: "bolt.fill")
                .labelStyle(.titleAndIcon)
                .font(NL.Typography.label.monospacedDigit())
                .foregroundStyle(streak.includesToday ? GoalColor.color(.reached) : .secondary)
                // Spoken as part of the tile's label (`accessibilityLabel(of:state:)`).
                .accessibilityHidden(true)
        }
    }
}
