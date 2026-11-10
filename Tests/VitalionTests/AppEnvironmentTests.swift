import Foundation
import Persistence
import Testing
@testable import Vitalion

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
        let config = AppConfig(usdaAPIKey: nil)
        #expect(config.usdaAPIKey == nil)
        #expect(config.offContact == AppConfig.defaultOFFContact)
    }

    @Test func `main bundle config reads info plist`() {
        let config = AppConfig(bundle: .main)
        #expect(config.offContact.contains("github.com/memphin/vitalion"))
        #expect(!config.appVersion.isEmpty)
    }
}

@MainActor
struct AppEnvironmentBehaviourTests {
    @Test func `energy unit preference is persisted`() throws {
        let env = AppEnvironment.preview()
        #expect(env.energyUnit == .kcal)
        try env.setEnergyUnit(.kilojoules)
        #expect(env.energyUnit == .kilojoules)
        #expect(try env.profiles?.setting(SettingKey.energyUnit, as: String.self) == "kJ")
    }

    @Test func `import reloads cached settings and bumps the data generation`() throws {
        let env = AppEnvironment.preview()
        let portability = try #require(env.portability)
        try env.setEnergyUnit(.kilojoules)
        let exported = try portability.exportJSON()
        try env.setEnergyUnit(.kcal)

        try portability.importJSON(exported, mode: .replace)
        #expect(env.energyUnit == .kcal) // stale until told
        try env.dataDidChangeExternally()
        #expect(env.energyUnit == .kilojoules)
        #expect(env.dataGeneration == 1)
    }

    @Test func `today is refreshed from the clock`() {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let start = env.today
        #expect(!env.refreshToday()) // same day
        clock.advance(hours: 24)
        #expect(env.refreshToday())
        #expect(env.today == start.next)
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
