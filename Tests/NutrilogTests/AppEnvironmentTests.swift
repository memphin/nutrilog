import Foundation
import Testing
@testable import Nutrilog

@MainActor
struct AppEnvironmentTests {
    @Test func `preview environment has ready database`() {
        let env = AppEnvironment.preview()
        guard case .ready = env.database else {
            Issue.record("expected in-memory database to open")
            return
        }
    }

    @Test func `empty USDA key is treated as missing`() {
        let config = AppConfig(usdaAPIKey: nil, offUserAgent: AppConfig.defaultUserAgent)
        #expect(config.usdaAPIKey == nil)
        #expect(config.offUserAgent.hasPrefix("Nutrilog/"))
    }

    @Test func `main bundle config reads info plist`() {
        let config = AppConfig(bundle: .main)
        #expect(config.offUserAgent.contains("github.com/memphin/nutrilog"))
    }
}
