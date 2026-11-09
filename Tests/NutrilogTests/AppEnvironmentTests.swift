import Foundation
import Persistence
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

@MainActor
struct AppEnvironmentBehaviourTests {
    @Test func `energy unit preference is persisted`() throws {
        let env = AppEnvironment.preview()
        #expect(env.energyUnit == .kcal)
        env.energyUnit = .kilojoules
        #expect(try env.profiles?.setting(SettingKey.energyUnit, as: String.self) == "kJ")
    }

    @Test func `bundled food index ships with the app`() throws {
        let index = try #require(BundledFoodIndex.inBundle(.main))
        #expect(try index.count() >= 300)
    }

    @Test func `sample data fills today`() throws {
        let env = AppEnvironment.preview(sampleData: true)
        let diary = try #require(try env.diary?.diary(for: env.today))
        #expect(diary.entryCount == 3)
        #expect(try env.profiles?.target(on: env.today)?.kcal == 2200)
    }
}
