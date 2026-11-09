import Foundation

/// Build-time configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfig: Sendable {
    static let defaultUserAgent = "Nutrilog/0.1 (https://github.com/memphin/nutrilog)"

    /// Optional USDA FoodData Central key; nil when not configured (online USDA search hidden).
    let usdaAPIKey: String?
    /// User-Agent sent to Open Food Facts, as required by their terms.
    let offUserAgent: String

    init(usdaAPIKey: String?, offUserAgent: String) {
        self.usdaAPIKey = usdaAPIKey
        self.offUserAgent = offUserAgent
    }

    init(bundle: Bundle) {
        let key = (bundle.object(forInfoDictionaryKey: "USDAFDCAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces)
        usdaAPIKey = (key?.isEmpty ?? true) ? nil : key
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let contact = (bundle.object(forInfoDictionaryKey: "OFFUserAgentContact") as? String) ?? ""
        offUserAgent = contact.isEmpty ? Self.defaultUserAgent : "Nutrilog/\(version) (\(contact))"
    }
}
