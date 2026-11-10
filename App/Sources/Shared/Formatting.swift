import Core
import DesignSystem
import Foundation
import Persistence

extension FoodSource {
    var badge: SourceBadge.Kind {
        switch self {
        // `.recipe` is legacy (issue #68): such a food is an ordinary custom food.
        case .custom, .recipe: .custom
        case .bundled: .bundled
        case .off: .off
        case .usda: .usda
        }
    }
}

enum Format {
    /// "150 g", "250 ml", "2 × slice (50 g)".
    static func amount(grams: Double, unit: BaseUnit, servingLabel: String?) -> String {
        let base = "\(NutrientRow.format(grams, unit: unit.symbol)) \(unit.symbol)"
        guard let servingLabel else { return base }
        return "\(servingLabel) (\(base))"
    }

    static func day(_ day: LocalDay, today: LocalDay) -> String {
        switch today.days(until: day) {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default:
            let date = day.startDate()
            let sameYear = day.year == today.year
            return date.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                : .dateTime.day().month(.abbreviated).year())
        }
    }

    /// Parses user input with either "," or "." as decimal separator. Empty → nil.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    /// Value → text for editable fields ("12.5", "" for nil); uses the user's decimal separator.
    static func field(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0 ... 2)).grouping(.never))
    }
}
