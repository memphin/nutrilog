import Foundation
import Persistence
import Synchronization
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

    @Test func `bundled coffee, tea and cola carry caffeine`() throws {
        let index = try #require(BundledFoodIndex.inBundle(.main))
        let caffeine = try index.caffeineBySourceID()
        #expect(caffeine["171890"] == 40) // coffee, brewed
        #expect(caffeine["173227"] == 20) // tea, black, brewed
        #expect(caffeine["174852"] == 9) // cola
        // Ids are stable across rebuilds (UUIDv5 of "fdc:<FDC id>").
        #expect(try index.food(id: "ddd499e7-724f-5469-84c9-36311e1f25ac")?.sourceID == "171890")
    }

    @Test func `sample data fills today`() throws {
        let env = AppEnvironment.preview(sampleData: true)
        let diary = try #require(try env.diary?.diary(for: env.today))
        #expect(diary.entryCount == 3)
        #expect(try env.profiles?.target(on: env.today)?.kcal == 2200)
    }
}

/// Records what is scheduled; "notifications allowed" is set by the test.
final class RecordingCheckInReminder: CheckInReminderScheduling {
    enum Call: Equatable {
        case schedule(weekday: Int, hour: Int)
        case cancel
        case requestAuthorization
    }

    private let state: Mutex<(authorized: Bool, calls: [Call])>

    init(authorized: Bool) {
        state = Mutex((authorized, []))
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func requestAuthorization() async -> Bool {
        state.withLock { state in
            state.calls.append(.requestAuthorization)
            return state.authorized
        }
    }

    func isAuthorized() async -> Bool {
        state.withLock { $0.authorized }
    }

    func schedule(weekday: Int, hour: Int) async throws {
        state.withLock { $0.calls.append(.schedule(weekday: weekday, hour: hour)) }
    }

    func cancel() async {
        state.withLock { $0.calls.append(.cancel) }
    }
}

/// The check-in reminder follows the stored toggle after an import or restore, and at launch (backlog #35).
@MainActor
struct CheckInReminderReconcileTests {
    @Test func `an import that turns the reminder on schedules it without asking for permission`() async throws {
        let reminder = RecordingCheckInReminder(authorized: true)
        let env = AppEnvironment.preview(checkInReminder: reminder)
        let profiles = try #require(env.profiles)
        var profile = try profiles.profile()
        profile.checkinWeekday = 5
        try profiles.save(profile)
        try profiles.setSetting(SettingKey.checkInReminderEnabled, true)

        try env.dataDidChangeExternally()
        #expect(await waitUntil { !reminder.calls.isEmpty })
        #expect(reminder.calls == [.schedule(weekday: 5, hour: LocalNotificationCheckInReminder.defaultHour)])
    }

    @Test func `without notification permission nothing is scheduled and nobody is asked`() async throws {
        let reminder = RecordingCheckInReminder(authorized: false)
        let env = AppEnvironment.preview(checkInReminder: reminder)
        try #require(env.profiles).setSetting(SettingKey.checkInReminderEnabled, true)
        await env.reconcileCheckInReminder()?.value
        #expect(reminder.calls.isEmpty)
    }

    @Test func `an import that turns the reminder off cancels it`() async throws {
        let reminder = RecordingCheckInReminder(authorized: true)
        let env = AppEnvironment.preview(checkInReminder: reminder)
        try #require(env.profiles).setSetting(SettingKey.checkInReminderEnabled, false)
        await env.reconcileCheckInReminder()?.value
        #expect(reminder.calls == [.cancel])

        // Missing (a fresh install) means off too.
        let fresh = RecordingCheckInReminder(authorized: true)
        await AppEnvironment.preview(checkInReminder: fresh).reconcileCheckInReminder()?.value
        #expect(fresh.calls == [.cancel])
    }
}
