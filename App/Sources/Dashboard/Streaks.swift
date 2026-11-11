import Core
import DesignSystem
import Foundation
import SwiftUI

// Streaks: days in a row the step, sleep and water goals were reached, shown as a small badge on those tiles.
// Past days are measured against today's goals (goals have no history).

extension DashboardSnapshot {
    /// The tiles that have a streak.
    static let streakTiles: [DashboardTile] = [.steps, .sleep, .water]

    /// The tile's streak; nil for tiles without a daily goal.
    func streak(for tile: DashboardTile) -> Streak? {
        streaks[tile]
    }

    static func streaks(data: DashboardData, rows: [DailyHealthMetrics]) -> [DashboardTile: Streak] {
        let metrics = Dictionary(rows.map { ($0.day, $0) }) { first, _ in first }
        func streak(_ reached: (LocalDay) -> Bool) -> Streak {
            Streak.current(today: data.today, maxDays: DashboardData.historyDays, reached: reached)
        }
        return [
            .steps: streak { day in
                guard let steps = metrics[day]?.steps else { return false }
                return StepGoal.band(steps: Double(steps), goal: data.stepGoal) == .reached
            },
            // Like the tile: time asleep, or time in bed when that is all Health has.
            .sleep: streak { day in
                guard let row = metrics[day], let minutes = row.sleepAsleepMin ?? row.sleepInBedMin else { return false }
                return SleepGoal.band(minutes: Double(minutes), goal: data.sleepGoalMin) == .reached
            },
            // Like the tile: logged in Vitalion plus other apps' water.
            .water: streak { day in
                let ml = (data.waterByDay[day] ?? 0) + (metrics[day]?.waterMl ?? 0)
                return data.waterGoalMl > 0 && ml >= data.waterGoalMl
            },
        ]
    }
}

/// The flame and day count in a tile's header; nothing when there is no streak.
struct StreakBadge: View {
    let streak: Streak

    /// "5", "60+".
    nonisolated static func text(_ streak: Streak) -> String {
        streak.isAtLimit ? "\(streak.days)+" : "\(streak.days)"
    }

    /// "5-day streak"; nil without a streak.
    nonisolated static func spoken(_ streak: Streak) -> String? {
        guard streak.days > 0 else { return nil }
        return "\(streak.days)-day streak" + (streak.isAtLimit ? " or more" : "")
    }

    var body: some View {
        if streak.days > 0 {
            // Green once today counts too; secondary while today is still open.
            Label(Self.text(streak), systemImage: "flame.fill")
                .labelStyle(.titleAndIcon)
                .font(NL.Typography.label.monospacedDigit())
                .foregroundStyle(streak.includesToday ? GoalColor.color(.reached) : .secondary)
                // Spoken as part of the tile's label (`accessibilityLabel(of:state:)`).
                .accessibilityHidden(true)
        }
    }
}
