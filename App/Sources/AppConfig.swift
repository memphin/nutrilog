import Core
import Foundation

/// Build-time configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfig: Sendable {
    /// Used when Info.plist has no `OFFUserAgentContact` (OFF requires a contact in the User-Agent).
    static let defaultOFFContact = "https://github.com/memphin/vitalion"

    /// Optional USDA FoodData Central key; nil when not configured (online USDA search hidden).
    let usdaAPIKey: String?
    /// How Open Food Facts can reach the maintainer (Info.plist `OFFUserAgentContact`), for the User-Agent the OFF
    /// client builds (`Vitalion/<appVersion> (<contact>)`, as their terms require); never blank.
    let offContact: String
    /// `CFBundleShortVersionString`, for User-Agents.
    let appVersion: String

    init(usdaAPIKey: String?, offContact: String = AppConfig.defaultOFFContact, appVersion: String = "0.1") {
        self.usdaAPIKey = usdaAPIKey
        self.offContact = offContact
        self.appVersion = appVersion
    }

    init(bundle: Bundle) {
        let key = (bundle.object(forInfoDictionaryKey: "USDAFDCAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces)
        usdaAPIKey = (key?.isEmpty ?? true) ? nil : key
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        offContact = (bundle.object(forInfoDictionaryKey: "OFFUserAgentContact") as? String).trimmedNonEmpty
            ?? Self.defaultOFFContact
    }
}
