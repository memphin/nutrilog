import Foundation

/// Build-time configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfig: Sendable {
    static let defaultUserAgent = "Nutrilog/0.1 (https://github.com/memphin/nutrilog)"
    /// Used when Info.plist has no `OFFUserAgentContact` (OFF requires a contact in the User-Agent).
    static let defaultOFFContact = "https://github.com/memphin/nutrilog"

    /// Optional USDA FoodData Central key; nil when not configured (online USDA search hidden).
    let usdaAPIKey: String?
    /// User-Agent sent to Open Food Facts, as required by their terms.
    let offUserAgent: String
    /// How Open Food Facts can reach the maintainer (Info.plist `OFFUserAgentContact`); never blank.
    let offContact: String
    /// `CFBundleShortVersionString`, for User-Agents.
    let appVersion: String

    init(
        usdaAPIKey: String?,
        offUserAgent: String,
        offContact: String = AppConfig.defaultOFFContact,
        appVersion: String = "0.1",
    ) {
        self.usdaAPIKey = usdaAPIKey
        self.offUserAgent = offUserAgent
        self.offContact = offContact
        self.appVersion = appVersion
    }

    init(bundle: Bundle) {
        let key = (bundle.object(forInfoDictionaryKey: "USDAFDCAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces)
        usdaAPIKey = (key?.isEmpty ?? true) ? nil : key
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let contact = ((bundle.object(forInfoDictionaryKey: "OFFUserAgentContact") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        offUserAgent = contact.isEmpty ? Self.defaultUserAgent : "Nutrilog/\(version) (\(contact))"
        offContact = contact.isEmpty ? Self.defaultOFFContact : contact
        appVersion = version
    }
}
