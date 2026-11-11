import Core
import Foundation
import Persistence

// MARK: - Settings

/// Settings → Caffeine: the sleep-safe line, bedtime, what changes the half-life, and the quick-add drinks. Each value
/// is its own `SettingKey`; missing or unusable values fall back to the defaults.
struct CaffeineSettings: Equatable {
    static let thresholdRange = 10.0 ... 200.0
    static let thresholdStep = 10.0
    static let halfLifeStep = 0.5
    static let maximumQuickAdd = 4

    var thresholdMg = CaffeineDefaults.sleepSafeThresholdMg
    /// Minutes from midnight.
    var bedtimeMinutes = CaffeineDefaults.defaultBedtimeMinutes
    var metabolism = CaffeineMetabolism()
    var quickAddIDs = CaffeineDrink.defaultQuickAddIDs
    var dailyLimitMg = CaffeineDefaults.dailyLimitMg

    static let `default` = CaffeineSettings()

    /// The presets of the quick-add buttons, in the chosen order.
    var quickAddDrinks: [CaffeineDrink] {
        quickAddIDs.compactMap(CaffeineDrink.preset(id:))
    }

    var model: CaffeineModel {
        metabolism.model
    }

    /// In `thresholdRange`, on a `thresholdStep` step.
    static func normalizedThreshold(_ mg: Double) -> Double {
        guard mg.isFinite else { return CaffeineDefaults.sleepSafeThresholdMg }
        let stepped = (mg / thresholdStep).rounded() * thresholdStep
        return min(max(stepped, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    /// 0 ..< 24 h.
    static func normalizedBedtime(_ minutes: Int) -> Int {
        ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
    }

    /// Within `CaffeineMetabolism.halfLifeRange`, on a `halfLifeStep` step.
    static func normalizedHalfLife(_ hours: Double) -> Double {
        let range = CaffeineMetabolism.halfLifeRange
        guard hours.isFinite else { return CaffeineMetabolism.baseHalfLifeHours }
        let stepped = (hours / halfLifeStep).rounded() * halfLifeStep
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// Known presets only, no duplicates, at most `maximumQuickAdd`; the defaults when none is left.
    static func normalizedQuickAdd(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        let valid = ids.filter { CaffeineDrink.preset(id: $0) != nil && seen.insert($0).inserted }
        return valid.isEmpty ? CaffeineDrink.defaultQuickAddIDs : Array(valid.prefix(maximumQuickAdd))
    }

    static func load(from settings: ProfileRepository) -> CaffeineSettings {
        func read<T: Codable & Sendable>(_ key: String, _: T.Type) -> T? {
            (try? settings.setting(key, as: T.self)) ?? nil
        }
        var result = CaffeineSettings()
        if let mg = read(SettingKey.caffeineThresholdMg, Double.self) {
            result.thresholdMg = normalizedThreshold(mg)
        }
        if let minutes = read(SettingKey.caffeineBedtimeMinutes, Int.self) {
            result.bedtimeMinutes = normalizedBedtime(minutes)
        }
        let override = read(SettingKey.caffeineHalfLifeOverride, Double?.self) ?? nil
        result.metabolism = CaffeineMetabolism(
            smoker: read(SettingKey.caffeineSmoker, Bool.self) ?? false,
            oralContraceptives: read(SettingKey.caffeinePill, Bool.self) ?? false,
            pregnant: read(SettingKey.caffeinePregnant, Bool.self) ?? false,
            overrideHours: override.map(normalizedHalfLife),
        )
        if let ids = read(SettingKey.caffeineQuickAddDrinks, [String].self) {
            result.quickAddIDs = normalizedQuickAdd(ids)
        }
        return result
    }

    /// Saves every value, normalized; returns what was saved.
    @discardableResult
    func save(to settings: ProfileRepository) throws -> CaffeineSettings {
        var saved = self
        saved.thresholdMg = Self.normalizedThreshold(thresholdMg)
        saved.bedtimeMinutes = Self.normalizedBedtime(bedtimeMinutes)
        saved.metabolism.overrideHours = metabolism.overrideHours.map(Self.normalizedHalfLife)
        saved.quickAddIDs = Self.normalizedQuickAdd(quickAddIDs)
        try settings.setSetting(SettingKey.caffeineThresholdMg, saved.thresholdMg)
        try settings.setSetting(SettingKey.caffeineBedtimeMinutes, saved.bedtimeMinutes)
        try settings.setSetting(SettingKey.caffeineSmoker, saved.metabolism.smoker)
        try settings.setSetting(SettingKey.caffeinePill, saved.metabolism.oralContraceptives)
        try settings.setSetting(SettingKey.caffeinePregnant, saved.metabolism.pregnant)
        // null (not a missing row) when derived: the setting table has no delete.
        try settings.setSetting(SettingKey.caffeineHalfLifeOverride, saved.metabolism.overrideHours)
        try settings.setSetting(SettingKey.caffeineQuickAddDrinks, saved.quickAddIDs)
        return saved
    }
}

// MARK: - Level bands

/// The colour of the caffeine tile's number:
/// - green (`.reached`): below the sleep-safe threshold (default 50 mg);
/// - orange (`.near`): from the threshold up to `highMg` (200 mg, the single dose EFSA considers unproblematic for
///   healthy adults), or twice the threshold when that is higher;
/// - red (`.far`): at or above that, or whenever today's total is over the daily limit (400 mg).
enum CaffeineLevel {
    static let highMg = 200.0

    /// The band of the amount in the body.
    static func band(mg: Double, thresholdMg: Double) -> GoalBand {
        if mg < thresholdMg {
            return .reached
        }
        return mg < max(highMg, 2 * thresholdMg) ? .near : .far
    }

    /// The band shown: the amount's band, red when today's total is over the daily limit.
    static func band(mg: Double, thresholdMg: Double, todayTotalMg: Double, dailyLimitMg: Double) -> GoalBand {
        isOverLimit(totalMg: todayTotalMg, limitMg: dailyLimitMg) ? .far : band(mg: mg, thresholdMg: thresholdMg)
    }

    static func isOverLimit(totalMg: Double, limitMg: Double) -> Bool {
        limitMg > 0 && totalMg > limitMg
    }
}

// MARK: - Status

/// Caffeine at one moment: the amount in the body, today's total, the amount at bedtime and when it is sleep-safe,
/// plus the curves the tile and the detail draw. Pure (no clock, no database), so the rules are unit-tested; the
/// view recomputes it every minute.
struct CaffeineStatus: Equatable {
    /// What the tile says about sleep.
    enum SleepOutlook: Equatable {
        /// Below the threshold now, and nothing taken lifts it back above.
        case safeNow
        /// Above it now, below it by `Date` (before bedtime, or bedtime has passed).
        case belowBy(Date)
        /// Still above the threshold at the coming bedtime: about `mg` then.
        case aboveAtBedtime(bedtime: Date, mg: Double)
    }

    /// Bedtime counts as "tonight" until this long after it (up late, or asleep).
    static let bedtimeGrace: TimeInterval = 6 * 3600
    /// The curves start at this hour of the morning.
    static let morningHour = 6
    /// The detail curve runs until this hour of the next day.
    static let detailEndHour = 3

    let now: Date
    let mgNow: Double
    let thresholdMg: Double
    let halfLifeHours: Double
    let dailyLimitMg: Double
    /// Logged on `today`, both sources.
    let todayTotalMg: Double
    /// Tonight's bedtime: the next one, or the last one when it passed less than `bedtimeGrace` ago.
    let bedtime: Date
    let mgAtBedtime: Double
    /// From when the amount stays below the threshold (`now` when it already does); nil when not within 2 days.
    let safeAt: Date?
    let outlook: SleepOutlook
    /// Start of the curves: 06:00 of the day the evening belongs to.
    let morning: Date

    private let doses: [CaffeineDose]
    private let model: CaffeineModel
    private let calendar: Calendar

    init(intakes: CaffeineIntakes, settings: CaffeineSettings, today: LocalDay, now: Date, calendar: Calendar = .current) {
        let doses = intakes.doses
        let model = settings.model
        self.now = now
        self.doses = doses
        self.model = model
        self.calendar = calendar
        thresholdMg = settings.thresholdMg
        halfLifeHours = model.halfLifeHours
        dailyLimitMg = settings.dailyLimitMg
        mgNow = model.amount(at: now, doses: doses)
        todayTotalMg = intakes.totalMg(on: today)
        let bedtime = Self.bedtime(near: now, minutes: settings.bedtimeMinutes, calendar: calendar)
        self.bedtime = bedtime
        mgAtBedtime = model.amount(at: bedtime, doses: doses)
        let safeAt = model.firstTimeBelow(threshold: settings.thresholdMg, after: now, doses: doses)
        self.safeAt = safeAt
        outlook = if safeAt == now {
            .safeNow
        } else if let safeAt, bedtime <= now || safeAt <= bedtime {
            .belowBy(safeAt)
        } else {
            .aboveAtBedtime(bedtime: bedtime, mg: model.amount(at: bedtime, doses: doses))
        }
        morning = Self.morning(of: now, calendar: calendar)
    }

    // MARK: Bands

    var band: GoalBand {
        CaffeineLevel.band(mg: mgNow, thresholdMg: thresholdMg, todayTotalMg: todayTotalMg, dailyLimitMg: dailyLimitMg)
    }

    var isOverDailyLimit: Bool {
        CaffeineLevel.isOverLimit(totalMg: todayTotalMg, limitMg: dailyLimitMg)
    }

    // MARK: Text

    /// "85" (whole mg).
    static func mgNumber(_ mg: Double) -> String {
        max(mg, 0).formatted(.number.precision(.fractionLength(0)))
    }

    /// "85 mg".
    static func mg(_ mg: Double) -> String {
        "\(mgNumber(mg)) mg"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Sleep-safe now", "Below 50 mg by 21:40", "Above 50 mg at bedtime (23:00)".
    func outlookText(time: (Date) -> String = CaffeineStatus.time) -> String {
        let threshold = Self.mg(thresholdMg)
        return switch outlook {
        case .safeNow: "Sleep-safe now"
        case let .belowBy(date): "Below \(threshold) by \(time(date))"
        case let .aboveAtBedtime(bedtime, _): "Above \(threshold) at bedtime (\(time(bedtime)))"
        }
    }

    /// "Today 159 of 400 mg".
    var todayText: String {
        "Today \(Self.mgNumber(todayTotalMg)) of \(Self.mg(dailyLimitMg))"
    }

    /// For VoiceOver: "85 milligrams now", "below 50 milligrams by 21:40", "159 of 400 milligrams today".
    func accessibilityParts(time: (Date) -> String = CaffeineStatus.time) -> [String] {
        let threshold = "\(Self.mgNumber(thresholdMg)) milligrams"
        let outlookPart = switch outlook {
        case .safeNow: "sleep-safe now, below \(threshold)"
        case let .belowBy(date): "below \(threshold) by \(time(date))"
        case let .aboveAtBedtime(bedtime, mg): "about \(Self.mgNumber(mg)) milligrams at bedtime, \(time(bedtime))"
        }
        var parts = ["\(Self.mgNumber(mgNow)) milligrams now", outlookPart,
                     "\(Self.mgNumber(todayTotalMg)) of \(Self.mgNumber(dailyLimitMg)) milligrams today"]
        if isOverDailyLimit {
            parts.append("over the daily limit")
        }
        return parts
    }

    /// How the estimate works, with the half-life in use (the detail's footnote).
    static func explanation(halfLifeHours: Double) -> String {
        let hours = halfLifeHours.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "Estimated with a one-compartment model: each drink is absorbed over about 45 minutes, then cleared "
            + "with a half-life of \(hours) h (from Settings → Caffeine). Below the sleep-safe line, caffeine is "
            + "unlikely to keep you awake. People clear caffeine at very different speeds — this is an estimate, "
            + "not medical advice."
    }

    // MARK: Curves

    /// The tile's curve: from the morning to tonight's bedtime (at least an hour past now).
    var tileWindow: ClosedRange<Date> {
        let end = max(bedtime, now.addingTimeInterval(3600))
        return morning ... max(end, morning.addingTimeInterval(3600))
    }

    /// The detail's curve: from the morning (earlier when a dose of that day was) to 03:00 of the next day, at
    /// least two hours past bedtime and one past now.
    var detailWindow: ClosedRange<Date> {
        let morningDay = calendar.startOfDay(for: morning)
        let firstDose = doses.first { $0.at >= morningDay }?.at
        var start = morning
        if let firstDose, firstDose < start {
            start = calendar.dateInterval(of: .hour, for: firstDose)?.start ?? firstDose
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: morningDay) ?? morningDay.addingTimeInterval(86400)
        let night = calendar.date(bySettingHour: Self.detailEndHour, minute: 0, second: 0, of: nextDay) ?? nextDay
        let end = max(night, bedtime.addingTimeInterval(2 * 3600), now.addingTimeInterval(3600))
        return start ... end
    }

    func curve(in window: ClosedRange<Date>, step: TimeInterval) -> [CaffeinePoint] {
        model.curve(from: window.lowerBound, to: window.upperBound, step: step, doses: doses)
    }

    func amount(at date: Date) -> Double {
        model.amount(at: date, doses: doses)
    }

    // MARK: Times

    /// Bedtime at `minutes` past midnight: the first one at or after `now − bedtimeGrace`.
    static func bedtime(near now: Date, minutes: Int, calendar: Calendar) -> Date {
        let minutes = CaffeineSettings.normalizedBedtime(minutes)
        let earliest = now.addingTimeInterval(-bedtimeGrace)
        let day = calendar.startOfDay(for: earliest)
        for offset in 0 ... 2 {
            guard let base = calendar.date(byAdding: .day, value: offset, to: day),
                  let candidate = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base)
            else { continue }
            if candidate >= earliest {
                return candidate
            }
        }
        return now
    }

    /// 06:00 of the day the evening belongs to: before 06:00 (up late) that's yesterday's.
    static func morning(of now: Date, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now) ?? now
        if now >= today {
            return today
        }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86400)
    }
}

// MARK: - Today's intakes

/// One caffeine intake of the detail list: a quick-add (deletable) or a diary entry (read-only).
struct CaffeineIntakeRow: Equatable, Identifiable {
    enum Source: Equatable {
        case quickAdd(CaffeineEntry)
        case diary
    }

    var id: String
    var name: String
    var at: Date
    var mg: Double
    var source: Source

    /// The intakes logged on `day`, newest first.
    static func rows(_ intakes: CaffeineIntakes, on day: LocalDay) -> [CaffeineIntakeRow] {
        let quick = intakes.quickAdds.filter { $0.day == day }.map { entry in
            CaffeineIntakeRow(
                id: "q-\(entry.id)",
                name: entry.name ?? entry.drinkID.flatMap(CaffeineDrink.preset(id:))?.name ?? "Caffeine",
                at: entry.loggedAt, mg: entry.mg, source: .quickAdd(entry),
            )
        }
        let diary = intakes.diary.filter { $0.day == day }.map {
            CaffeineIntakeRow(id: "d-\($0.id)", name: $0.name, at: $0.loggedAt, mg: $0.mg, source: .diary)
        }
        return (quick + diary).sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }
}
