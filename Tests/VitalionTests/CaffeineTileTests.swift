import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// The caffeine tile's pure rules: amount now, sleep outlook and its wording, colour bands, settings, layout.
struct CaffeineStatusTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        return calendar
    }()

    let today = LocalDay("2026-11-09")!

    /// `hour:minute` on `today` (or `days` later).
    func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: today.startDate(calendar: calendar))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func dose(_ mg: Double, at date: Date, name: String = "Coffee") -> DiaryCaffeineIntake {
        DiaryCaffeineIntake(id: UUID().uuidString, day: LocalDay(date, calendar: calendar), loggedAt: date, mg: mg, name: name)
    }

    func status(_ doses: [DiaryCaffeineIntake], now: Date, settings: CaffeineSettings = .default) -> CaffeineStatus {
        CaffeineStatus(
            intakes: CaffeineIntakes(diary: doses), settings: settings, today: LocalDay(now, calendar: calendar), now: now,
            calendar: calendar,
        )
    }

    func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    @Test func `nothing logged: zero, sleep-safe, green`() {
        let status = status([], now: at(10))
        #expect(status.mgNow == 0)
        #expect(status.outlook == .safeNow)
        #expect(status.band == .reached)
        #expect(status.outlookText(time: time) == "Sleep-safe now")
        #expect(status.todayText == "Today 0 of 400 mg")
    }

    @Test func `the amount now follows the model with the settings' half-life`() {
        let doses = [dose(64, at: at(8)), dose(95, at: at(13))]
        var settings = CaffeineSettings.default
        settings.metabolism.smoker = true
        let status = status(doses, now: at(15), settings: settings)
        let expected = CaffeineModel(halfLifeHours: 3).amount(at: at(15), doses: doses.map(\.dose))
        #expect(abs(status.mgNow - expected) < 1e-9)
        #expect(status.halfLifeHours == 3)
        #expect(status.todayTotalMg == 159)
        #expect(status.todayText == "Today 159 of 400 mg")
    }

    @Test func `a morning coffee is below the line well before bedtime`() throws {
        let status = status([dose(95, at: at(8))], now: at(9))
        #expect(status.band == .near) // ~85 mg: above 50, below 200
        guard case let .belowBy(date) = status.outlook else {
            Issue.record("expected belowBy, got \(status.outlook)")
            return
        }
        #expect(date > at(9) && date < status.bedtime)
        #expect(status.amount(at: date) < 50.01)
        #expect(status.outlookText(time: time) == "Below 50 mg by \(time(date))")
        #expect(status.bedtime == at(23))
    }

    @Test func `a big evening dose is still above the line at bedtime`() {
        let status = status([dose(200, at: at(20))], now: at(20, 30))
        guard case let .aboveAtBedtime(bedtime, mg) = status.outlook else {
            Issue.record("expected aboveAtBedtime, got \(status.outlook)")
            return
        }
        #expect(bedtime == at(23))
        #expect(mg > 50)
        #expect(abs(mg - status.mgAtBedtime) < 1e-9)
        #expect(status.outlookText(time: time) == "Above 50 mg at bedtime (23:00)")
        #expect(status.accessibilityParts(time: time)[1] == "about \(CaffeineStatus.mgNumber(mg)) milligrams at bedtime, 23:00")
    }

    @Test func `after bedtime it says when the line is crossed`() {
        let status = status([dose(150, at: at(21))], now: at(23, 30))
        #expect(status.bedtime == at(23)) // tonight's, just passed
        guard case let .belowBy(date) = status.outlook else {
            Issue.record("expected belowBy, got \(status.outlook)")
            return
        }
        #expect(date > at(23, 30))
    }

    @Test func `a dose that is still being absorbed is not sleep-safe yet`() {
        // Two minutes after a double espresso: little in the blood yet, but it will rise above the line.
        let status = status([dose(128, at: at(16))], now: at(16, 2))
        #expect(status.mgNow < 50)
        #expect(status.outlook != .safeNow)
    }

    @Test func `yesterday evening's caffeine still counts this morning`() {
        let status = status([dose(300, at: at(22, days: -1))], now: at(7))
        #expect(status.mgNow > 50)
        #expect(status.todayTotalMg == 0)
    }

    @Test func `tonight's bedtime: the next one, or the last within six hours`() {
        #expect(CaffeineStatus.bedtime(near: at(14), minutes: 30, calendar: calendar) == at(0, 30, days: 1))
        #expect(CaffeineStatus.bedtime(near: at(1), minutes: 23 * 60, calendar: calendar) == at(23, days: -1))
        #expect(CaffeineStatus.bedtime(near: at(5, 30), minutes: 23 * 60, calendar: calendar) == at(23))
        #expect(CaffeineStatus.bedtime(near: at(22), minutes: 22 * 60, calendar: calendar) == at(22))
    }

    @Test func `curves run from the morning to bedtime and into the night`() {
        let status = status([dose(64, at: at(5))], now: at(12))
        #expect(status.tileWindow == at(6) ... at(23))
        // The detail starts at the hour of an earlier dose that day and ends at 03:00.
        #expect(status.detailWindow == at(5) ... at(3, days: 1))
        let curve = status.curve(in: status.tileWindow, step: 600)
        #expect(curve.first?.date == at(6))
        #expect(curve.last?.date == at(23))
        // Up late: the morning is yesterday's.
        #expect(CaffeineStatus.morning(of: at(1), calendar: calendar) == at(6, days: -1))
    }

    @Test func `colour bands: green below the line, orange to 200 mg, red above or over the daily limit`() {
        #expect(CaffeineLevel.band(mg: 49, thresholdMg: 50) == .reached)
        #expect(CaffeineLevel.band(mg: 50, thresholdMg: 50) == .near)
        #expect(CaffeineLevel.band(mg: 199, thresholdMg: 50) == .near)
        #expect(CaffeineLevel.band(mg: 200, thresholdMg: 50) == .far)
        // A high threshold keeps an orange band up to twice the threshold.
        #expect(CaffeineLevel.band(mg: 250, thresholdMg: 150) == .near)
        #expect(CaffeineLevel.band(mg: 300, thresholdMg: 150) == .far)
        // Over the daily limit is red whatever the amount now.
        #expect(CaffeineLevel.band(mg: 20, thresholdMg: 50, todayTotalMg: 401, dailyLimitMg: 400) == .far)
        #expect(CaffeineLevel.band(mg: 20, thresholdMg: 50, todayTotalMg: 400, dailyLimitMg: 400) == .reached)
        let status = status([dose(250, at: at(7)), dose(200, at: at(8))], now: at(22))
        #expect(status.isOverDailyLimit)
        #expect(status.band == .far)
        #expect(status.accessibilityParts(time: time).last == "over the daily limit")
    }

    @Test func `today's intakes list newest first, diary rows are read-only`() {
        let doses = [dose(64, at: at(8), name: "Espresso"), dose(30, at: at(9), name: "Dark chocolate"), dose(80, at: at(20, days: -1))]
        let rows = CaffeineIntakeRow.rows(CaffeineIntakes(diary: doses), on: today)
        #expect(rows.map(\.name) == ["Dark chocolate", "Espresso"])
        #expect(rows.allSatisfy { $0.source == .diary })
    }
}

@MainActor
struct CaffeineSettingsTests {
    @Test func `defaults, normalization and a round trip through the setting table`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        #expect(CaffeineSettings.load(from: profiles) == .default)
        #expect(CaffeineSettings.default.thresholdMg == 50)
        #expect(CaffeineSettings.default.bedtimeMinutes == 23 * 60)
        #expect(CaffeineSettings.default.quickAddDrinks == CaffeineDrink.defaultQuickAdd)

        var settings = CaffeineSettings.default
        settings.thresholdMg = 263 // clamped, stepped
        settings.bedtimeMinutes = -30 // 23:30
        settings.metabolism = CaffeineMetabolism(smoker: true, oralContraceptives: true, overrideHours: 7.3)
        settings.quickAddIDs = ["matcha", "unknown", "matcha", "cola", "espresso", "green_tea", "black_tea"]
        let saved = try settings.save(to: profiles)
        #expect(saved.thresholdMg == 200)
        #expect(saved.bedtimeMinutes == 23 * 60 + 30)
        #expect(saved.metabolism.overrideHours == 7.5)
        #expect(saved.metabolism.halfLifeHours == 7.5)
        #expect(saved.quickAddIDs == ["matcha", "cola", "espresso", "green_tea"])
        #expect(CaffeineSettings.load(from: profiles) == saved)

        // Back to the derived half-life: stored as null, read as nil.
        var derived = saved
        derived.metabolism.overrideHours = nil
        try derived.save(to: profiles)
        let loaded = CaffeineSettings.load(from: profiles)
        #expect(loaded.metabolism.overrideHours == nil)
        #expect(loaded.metabolism.halfLifeHours == 6) // 5 × 0.6 × 2
    }

    @Test func `unusable stored values fall back to the defaults`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        try profiles.setSetting(SettingKey.caffeineQuickAddDrinks, ["gone"])
        try profiles.setSetting(SettingKey.caffeineThresholdMg, "not a number")
        let loaded = CaffeineSettings.load(from: profiles)
        #expect(loaded.quickAddIDs == CaffeineDrink.defaultQuickAddIDs)
        #expect(loaded.thresholdMg == CaffeineDefaults.sleepSafeThresholdMg)
    }
}

@MainActor
struct CaffeineDashboardTests {
    @Test func `the caffeine tile follows water in the default layout and is added to saved layouts`() throws {
        #expect(DashboardTile.caffeine.isWide)
        #expect(!DashboardTile.caffeine.usesHealth)
        let order = DashboardLayout.default.order
        #expect(order.firstIndex(of: .caffeine) == order.firstIndex(of: .water).map { $0 + 1 })

        // A layout saved before the caffeine tile existed gets it after water, visible, in the user's order.
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        let saved = #"{"order":["weight","water","energy","sleep","bodyFat","steps","totalEnergy","restingHeartRate","hrv"],"hidden":["hrv"]}"#
        try profiles.setSetting(SettingKey.dashboardLayout, JSONDecoder().decode(RawLayout.self, from: Data(saved.utf8)))
        let layout = DashboardLayout.load(from: profiles)
        #expect(layout.order == [.weight, .water, .caffeine, .energy, .sleep, .bodyFat, .steps, .totalEnergy, .restingHeartRate, .hrv])
        #expect(layout.isVisible(.caffeine))
        #expect(layout.hidden == [.hrv])
    }

    private struct RawLayout: Codable, Sendable {
        var order: [String]
        var hidden: [String]
    }

    @Test func `the tile is ready without Health and is spoken with the amount and the outlook`() throws {
        let today = try #require(LocalDay("2026-11-09"))
        let snapshot = DashboardSnapshot(DashboardData(today: today))
        #expect(snapshot.state(of: .caffeine, access: .unavailable, isFirstSync: false) == .ready)
        let label = snapshot.accessibilityLabel(of: .caffeine, state: .ready, now: today.startDate().addingTimeInterval(10 * 3600))
        #expect(label == "Caffeine, 0 milligrams now, sleep-safe now, below 50 milligrams, 0 of 400 milligrams today")
    }

    @Test func `quick-add caffeine shows on the tile, undo removes it, delete and undo restore it`() async throws {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let model = DashboardModel(environment: env)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        model.addCaffeine(drink: .espresso)
        #expect(await waitUntil { model.data.caffeine.quickAdds.count == 1 })
        clock.advance(hours: 1)
        let status = model.caffeineStatus(at: model.now)
        #expect(status.todayTotalMg == 64)
        #expect(status.mgNow > 50 && status.mgNow < 64)
        #expect(model.todaysCaffeine.map(\.name) == ["Espresso"])

        model.undo.performUndo()
        #expect(await waitUntil { model.data.caffeine.quickAdds.isEmpty })

        // An earlier drink lands on its own day; deleting offers undo.
        let yesterday = clock.appClock.now().addingTimeInterval(-20 * 3600)
        model.addCaffeine(mg: 120, at: yesterday, drinkID: nil, name: "Cold brew")
        #expect(await waitUntil { model.data.caffeine.quickAdds.count == 1 })
        let entry = try #require(model.data.caffeine.quickAdds.first)
        #expect(entry.day == model.data.today.adding(days: -1))
        #expect(model.todaysCaffeine.isEmpty)
        model.deleteCaffeine(entry)
        #expect(await waitUntil { model.data.caffeine.quickAdds.isEmpty })
        model.undo.performUndo()
        #expect(await waitUntil { model.data.caffeine.quickAdds.count == 1 })
    }

    @Test func `settings saved in Settings reach the tile`() throws {
        let env = AppEnvironment.preview()
        let profiles = try #require(env.profiles)
        let model = DashboardModel(environment: env)
        var settings = CaffeineSettings.default
        settings.thresholdMg = 80
        settings.quickAddIDs = ["green_tea"]
        try settings.save(to: profiles)
        model.reloadSettings()
        #expect(model.data.caffeineSettings.thresholdMg == 80)
        #expect(model.snapshot.caffeineSettings.quickAddDrinks == [.greenTea])
    }

    @Test func `the detail history sums both sources per day`() async throws {
        let clock = ManualClock()
        let env = AppEnvironment.preview(clock: clock.appClock)
        let caffeine = try #require(env.caffeine)
        try caffeine.add(mg: 95, day: env.today, drinkID: "filter_coffee", name: "Filter coffee")
        try caffeine.add(mg: 64, day: env.today.adding(days: -2))
        let model = DashboardModel(environment: env)
        let rows = model.history(for: .caffeine)
        #expect(rows.count == TileHistory.days)
        #expect(rows[0].value == "95 mg")
        #expect(rows[1].value == nil)
        #expect(rows[2].value == "64 mg")
    }
}
