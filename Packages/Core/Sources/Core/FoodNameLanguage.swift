import Foundation

/// The language built-in food names are shown in (FR-74): the bundled index has an English and a Croatian name for
/// each food. Resolved from ``FoodNamePreference`` and the app language; the UI itself always follows iOS.
public enum FoodNameLanguage: String, Hashable, Sendable, CaseIterable {
    case english = "en"
    case croatian = "hr"

    /// The language of `localization`, the one iOS picked for the app (`Bundle.main.preferredLocalizations.first`):
    /// Croatian for "hr" and its regional forms, English otherwise.
    public init(localization: String?) {
        guard let localization else {
            self = .english
            return
        }
        let isCroatian = localization == "hr" || localization.hasPrefix("hr-") || localization.hasPrefix("hr_")
        self = isCroatian ? .croatian : .english
    }
}

/// Settings → Food names: *Same as app* (the default), *English* or *Croatian*. Stored by its raw value.
public enum FoodNamePreference: String, Hashable, Sendable, CaseIterable, Codable {
    case sameAsApp
    case english = "en"
    case croatian = "hr"

    public static let `default` = FoodNamePreference.sameAsApp

    /// The language food names are shown in: the chosen one, or `appLanguage` for *Same as app*.
    public func resolved(appLanguage: FoodNameLanguage) -> FoodNameLanguage {
        switch self {
        case .sameAsApp: appLanguage
        case .english: .english
        case .croatian: .croatian
        }
    }
}

/// The two names of a built-in food, and when a name stored from it may follow a change of ``FoodNameLanguage``.
///
/// Copies of built-in foods and the diary entries logged from them store the name shown at the time. They switch
/// language only while they still carry one of the two names exactly; a name the user changed is theirs and stays.
public struct BilingualFoodName: Hashable, Sendable {
    public var english: String
    /// Nil when the index has none (a blank name counts as none).
    public var croatian: String?

    public init(english: String, croatian: String?) {
        self.english = english
        self.croatian = croatian.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The name shown in `language`; English when there is no Croatian name.
    public func name(in language: FoodNameLanguage) -> String {
        switch language {
        case .english: english
        case .croatian: croatian ?? english
        }
    }

    /// The name in the other language, or nil when there is none or it is the same word.
    public func otherName(than language: FoodNameLanguage) -> String? {
        let shown = name(in: language)
        let other = language == .english ? croatian : english
        return other.flatMap { $0 == shown ? nil : $0 }
    }

    /// The name and local name a stored copy should have in `language`, or nil when it should stay as it is: its
    /// name isn't exactly one of the two names (the user renamed it), there is no Croatian name to switch to, or it
    /// already has them.
    public func switching(
        name: String, nameLocal: String?, to language: FoodNameLanguage,
    ) -> (name: String, nameLocal: String?)? {
        guard croatian != nil, name == english || name == croatian else { return nil }
        let target = (name: self.name(in: language), nameLocal: otherName(than: language))
        guard target.name != name || target.nameLocal != nameLocal else { return nil }
        return target
    }

    /// The name a logged entry (`diary_entry.display_name`, `planned_entry.display_name`) should show in
    /// `language`, or nil when it should stay: it isn't exactly one of the two names, there is no Croatian name, or
    /// it is already in `language`.
    public func switchingSnapshot(_ displayName: String, to language: FoodNameLanguage) -> String? {
        guard croatian != nil, displayName == english || displayName == croatian else { return nil }
        let target = name(in: language)
        return target == displayName ? nil : target
    }
}
