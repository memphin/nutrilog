import Core
import Foundation
import Observation
import Persistence

/// The ticks on the meal plan's prep list ("prepped" / "bought"), kept across launches (in `UserDefaults` when given).
///
/// A tick belongs to one food (`PrepItem.id`) in one date range of the list, and to the amount planned for it then:
/// it shows only while the list covers the same days and sums up the same portions and amount. Changing the days
/// hides it (switching back shows it again), and so does a change to that food's plan — another portion, a different
/// amount, one marked as eaten — since what was prepped no longer matches. Ticks whose range has started before today
/// can't come back (the list always starts today or tomorrow) and are dropped (`prune(before:)`).
@MainActor
@Observable
final class PrepTickStore {
    struct Tick: Codable, Equatable {
        var itemID: String
        var from: LocalDay
        var through: LocalDay
        var totalGrams: Double
        var portions: Int
        var kcal: Double

        init(_ item: PrepItem, in range: ClosedRange<LocalDay>) {
            itemID = item.id
            from = range.lowerBound
            through = range.upperBound
            totalGrams = item.totalGrams
            portions = item.portions
            kcal = item.nutrients.kcal
        }

        /// The same food, days and planned amount (up to rounding).
        func matches(_ other: Tick) -> Bool {
            itemID == other.itemID && from == other.from && through == other.through && portions == other.portions
                && abs(totalGrams - other.totalGrams) < 0.05 && abs(kcal - other.kcal) < 0.05
        }

        func isSameSlot(_ other: Tick) -> Bool {
            itemID == other.itemID && from == other.from && through == other.through
        }
    }

    static let defaultsKey = "mealPlan.prepTicks"

    private let defaults: UserDefaults?
    private(set) var ticks: [Tick]

    /// `defaults` keeps the ticks across launches; nil keeps them in memory (tests, previews).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        ticks = defaults?.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([Tick].self, from: $0) } ?? []
    }

    func isTicked(_ item: PrepItem, in range: ClosedRange<LocalDay>) -> Bool {
        let tick = Tick(item, in: range)
        return ticks.contains { $0.matches(tick) }
    }

    func setTicked(_ ticked: Bool, _ item: PrepItem, in range: ClosedRange<LocalDay>) {
        let tick = Tick(item, in: range)
        var updated = ticks.filter { !$0.isSameSlot(tick) }
        if ticked {
            updated.append(tick)
        }
        save(updated)
    }

    func toggle(_ item: PrepItem, in range: ClosedRange<LocalDay>) {
        setTicked(!isTicked(item, in: range), item, in: range)
    }

    /// Drops the ticks of lists that started before `today`.
    func prune(before today: LocalDay) {
        let kept = ticks.filter { $0.from >= today }
        if kept.count != ticks.count {
            save(kept)
        }
    }

    private func save(_ updated: [Tick]) {
        ticks = updated
        guard let defaults else { return }
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
