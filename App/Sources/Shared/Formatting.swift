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
    /// "150 g", "250 ml", "2 × slice (50 g)"; the number in `locale` ("1,5 g" in Croatian).
    static func amount(grams: Double, unit: BaseUnit, servingLabel: String?, locale: Locale = .current) -> String {
        let base = "\(NutrientRow.format(grams, unit: unit.symbol, locale: locale)) \(unit.symbol)"
        guard let servingLabel else { return base }
        return "\(servingLabel) (\(base))"
    }

    /// "Today", "Yesterday", "Tomorrow", else the date in `locale` ("Thu, Nov 12"; "čet, 12. stu" in Croatian).
    static func day(_ day: LocalDay, today: LocalDay, locale: Locale = .current) -> String {
        switch today.days(until: day) {
        case 0: return String(localized: "Today")
        case -1: return String(localized: "Yesterday")
        case 1: return String(localized: "Tomorrow")
        default:
            let date = day.startDate()
            let sameYear = day.year == today.year
            let style: Date.FormatStyle = sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                : .dateTime.day().month(.abbreviated).year()
            return date.formatted(style.locale(locale))
        }
    }

    /// The largest magnitude `number(_:)` accepts. Every field it parses (amounts, energy, grams, body weight,
    /// percentages) stays far below it; the screens apply their own, tighter limits on top.
    static let maxNumber: Double = 1_000_000

    /// Parses user input with either "," or "." as decimal separator. Empty, not finite ("inf", "nan") or beyond
    /// ±`maxNumber` ("1e30", 20 digits) → nil, so nonsense never reaches a calculation or an `Int` conversion.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, abs(value) <= maxNumber else { return nil }
        return value
    }

    /// "2,400": a whole number, grouped for `locale`.
    static func whole(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// "1,840 ml".
    static func ml(_ value: Double) -> String {
        "\(whole(value)) ml"
    }

    /// "72.4": a body weight to `fractionDigits` decimals, without the unit.
    static func kgNumber(_ value: Double, fractionDigits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// "72.4 kg".
    static func kg(_ value: Double, fractionDigits: Int = 1) -> String {
        "\(kgNumber(value, fractionDigits: fractionDigits)) kg"
    }

    /// "−0.4 kg", "+0.2 kg", "±0.0 kg".
    static func kgChange(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : "±"
        return "\(sign)\(kg(abs(rounded)))"
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) %"
    }

    static func bpm(_ value: Double) -> String {
        "\(whole(value)) bpm"
    }

    static func ms(_ value: Double) -> String {
        "\(whole(value)) ms"
    }

    /// "7 h 5 min", "8 h", "45 min"; the unit abbreviations come from the string catalog. Spoken durations are
    /// `DashboardAccessibility`'s.
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return String(localized: "\(rest) min", comment: "Short duration in minutes") }
        return rest == 0
            ? String(localized: "\(hours) h", comment: "Short duration in hours")
            : String(localized: "\(hours) h \(rest) min", comment: "Short duration in hours and minutes")
    }

    /// "5 h", "1.5 h".
    static func hours(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0 ... 1)))
        return String(localized: "\(number) h", comment: "A duration in hours, e.g. “1.5 h”")
    }

    /// Value → text for editable fields ("12.5", "" for nil); uses the user's decimal separator.
    static func field(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0 ... 2)).grouping(.never).locale(locale))
    }
}
