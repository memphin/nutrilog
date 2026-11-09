import Foundation

/// Picks the meal slot to preselect when logging at a given time (FR-22, backlog #8).
public enum MealSlotSuggestion {
    public struct Slot: Hashable, Sendable {
        public let id: String
        public let startHour: Int?
        public let sortOrder: Int

        public init(id: String, startHour: Int?, sortOrder: Int) {
            self.id = id
            self.startHour = startHour
            self.sortOrder = sortOrder
        }
    }

    /// The slot with the latest `startHour` that is ≤ `hour`. Before the earliest start hour the last
    /// timed slot wins (late-night eating counts as the evening meal). Slots without a start hour
    /// (e.g. Snacks) are never preselected unless no slot has one.
    public static func slot(forHour hour: Int, among slots: [Slot]) -> String? {
        let timed = slots.filter { $0.startHour != nil }.sorted { $0.startHour! < $1.startHour! }
        guard !timed.isEmpty else { return slots.min { $0.sortOrder < $1.sortOrder }?.id }
        return timed.last { $0.startHour! <= hour }?.id ?? timed.last?.id
    }
}

/// Ranks recently logged foods so that the ones usually eaten in the current slot come first (backlog #8).
public enum RecentsRanking {
    public struct Usage: Hashable, Sendable {
        public let foodID: String
        /// How often the food was logged in the slot being opened (last 60 days).
        public let countInSlot: Int
        /// How often it was logged in any slot (last 60 days).
        public let countTotal: Int
        public let lastUsed: Date

        public init(foodID: String, countInSlot: Int, countTotal: Int, lastUsed: Date) {
            self.foodID = foodID
            self.countInSlot = countInSlot
            self.countTotal = countTotal
            self.lastUsed = lastUsed
        }
    }

    /// Score = slot frequency (weight 3) + overall frequency + recency bonus decaying over ~2 weeks.
    public static func score(_ usage: Usage, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(usage.lastUsed) / 86400)
        let recency = 5 * exp(-ageDays / 14)
        return Double(usage.countInSlot) * 3 + Double(usage.countTotal) + recency
    }

    public static func rank(_ usages: [Usage], now: Date) -> [String] {
        usages
            .sorted { lhs, rhs in
                let l = score(lhs, now: now), r = score(rhs, now: now)
                return l != r ? l > r : lhs.lastUsed > rhs.lastUsed
            }
            .map(\.foodID)
    }
}
