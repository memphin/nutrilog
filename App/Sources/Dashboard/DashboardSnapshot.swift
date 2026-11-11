import Core
import Foundation
import Persistence

/// Everything the dashboard reads from the database for one day (backlog #28).
struct DashboardData: Equatable {
    /// Days of history read for trends and baselines (weight EMA, 30-day HRV average, 14-day details).
    static let historyDays = 60

    var today: LocalDay
    /// `daily_metrics` rows of the history window (Health values from other sources).
    var metrics: [DailyMetricsRecord] = []
    /// Manual weights of the history window.
    var manualWeights: [WeightEntry] = []
    /// Every drink logged in Vitalion (water, diary drinks, caffeine drinks) per day over the history window, today
    /// included: today's for the tile, the sparkline's last 7 days and the hydration streak.
    var hydrationIntakes: [LocalDay: [FluidIntake]] = [:]
    /// Today's diary totals.
    var totals: Nutrients = .zero
    var target: Target?
    /// The weight each day of the history window's hydration goal uses: the latest weight trend on or before the
    /// day, however old (`HydrationGoalResolver.trendsKg(in:environment:)`).
    var weightTrends: [LocalDay: Double] = [:]
    /// The fixed hydration goal, used when `waterGoalMode` is `.fixed`.
    var waterGoalMl: Double = 2500
    var waterGoalMode: HydrationGoalMode = .weight
    var hydrationSettings = HydrationSettings.default
    var stepGoal: Int = StepGoal.defaultSteps
    var sleepGoalMin: Int = SleepGoal.defaultMinutes
    /// The profile's goal (lose, maintain, gain): which way the weight should move.
    var goalMode: GoalMode = .maintain
    /// Caffeine of `caffeineWindow` (quick-adds and diary entries): last night's still counts this morning.
    var caffeine = CaffeineIntakes()
    var caffeineSettings = CaffeineSettings.default

    var window: ClosedRange<LocalDay> {
        today.adding(days: -(Self.historyDays - 1)) ... today
    }

    /// The days of the tiles' sparklines, today included.
    var sparklineWindow: ClosedRange<LocalDay> {
        today.adding(days: -(Sparkline.days - 1)) ... today
    }

    /// Yesterday and today: the caffeine doses the curve needs.
    var caffeineWindow: ClosedRange<LocalDay> {
        today.adding(days: -1) ... today
    }

    /// [midnight of the window's first day, midnight after today) — manual weights to read.
    func weightInterval(calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: window.lowerBound.startDate(calendar: calendar), end: today.next.startDate(calendar: calendar))
    }

    /// The hydration goal of `day` (`HydrationGoalResolver`).
    func hydrationGoalMl(on day: LocalDay) -> Double {
        HydrationGoalResolver.goalMl(on: day, mode: waterGoalMode, fixedMl: waterGoalMl, trendKg: weightTrends[day])
    }
}

/// Today's hydration, whatever the time: every drink logged in Vitalion plus other apps' water from Health (FR-46).
/// Vitalion's own Health samples are already left out of `otherAppsMl`, so nothing is counted twice. Pace, gaps and
/// status depend on the time: `DashboardSnapshot.hydrationDay(now:calendar:)`.
struct WaterProgress: Equatable {
    /// Water, diary drinks and caffeine drinks logged in Vitalion.
    var loggedMl: Double
    var otherAppsMl: Double
    var goalMl: Double

    var totalMl: Double {
        loggedMl + otherAppsMl
    }

    /// `day`'s hydration read straight from the database (widget, Siri): the same total and goal as the tile.
    @MainActor
    static func read(on day: LocalDay, environment: AppEnvironment) throws -> WaterProgress? {
        guard let hydration = environment.hydration, let profiles = environment.profiles else { return nil }
        let logged = try HydrationTotals.loggedMl(hydration.intakes(in: day ... day))[day] ?? 0
        let other = (try? environment.dailyMetrics?.metrics(on: day)?.waterMl) ?? 0
        let trends = HydrationGoalResolver.trendsKg(in: day ... day, environment: environment)
        let goal = try HydrationGoalResolver.goalMl(on: day, profile: profiles.profile(), trendKg: trends[day])
        return WaterProgress(loggedMl: logged, otherAppsMl: other, goalMl: goal)
    }
}

/// The Hydration tile's texts (spec §3): "1,840 / 2,400 ml" and "1,300 water · 540 drinks", grouped by `locale`.
/// Water from other apps is water; "drinks" are all the others.
enum HydrationTileText {
    /// "1,840".
    static func amount(_ day: HydrationDay, locale: Locale = .autoupdatingCurrent) -> String {
        number(day.totalMl, locale)
    }

    /// "/ 2,400 ml".
    static func goal(_ day: HydrationDay, locale: Locale = .autoupdatingCurrent) -> String {
        "/ \(number(day.goalMl, locale)) ml"
    }

    /// "1,840 / 2,400 ml".
    static func total(_ day: HydrationDay, locale: Locale = .autoupdatingCurrent) -> String {
        "\(amount(day, locale: locale)) \(goal(day, locale: locale))"
    }

    /// "1,300 water · 540 drinks".
    static func breakdown(_ day: HydrationDay, locale: Locale = .autoupdatingCurrent) -> String {
        "\(number(day.waterMl + day.otherAppsMl, locale)) water · \(number(day.otherDrinksMl, locale)) drinks"
    }

    private static func number(_ ml: Double, _ locale: Locale) -> String {
        ml.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
}

struct SleepValue: Equatable {
    var asleepMin: Int?
    var inBedMin: Int?
    var coreMin: Int?
    var deepMin: Int?
    var remMin: Int?
    var awakeMin: Int?

    var hasStages: Bool {
        coreMin != nil || deepMin != nil || remMin != nil
    }
}

/// Energy burned on one day: active (exercise, movement) plus resting (basal). The total is shown only when both are
/// known — half of it presented as "total" would read as a low-burn day.
struct EnergyBurned: Equatable {
    var activeKcal: Double?
    var restingKcal: Double?

    /// nil unless both parts are known.
    var totalKcal: Double? {
        guard let activeKcal, let restingKcal else { return nil }
        return activeKcal + restingKcal
    }

    var hasValue: Bool {
        activeKcal != nil || restingKcal != nil
    }

    /// "Active 420 kcal · Resting 1,650 kcal"; a missing part says so.
    func breakdown(_ unit: EnergyUnit) -> String {
        [
            "Active \(activeKcal.map { unit.format($0) } ?? "unknown")",
            "Resting \(restingKcal.map { unit.format($0) } ?? "unknown")",
        ].joined(separator: " · ")
    }
}

struct BodyFatValue: Equatable {
    var day: LocalDay
    var pct: Double
}

/// The values of every tile, computed from `DashboardData` (pure, so the rules are unit-tested).
struct DashboardSnapshot: Equatable {
    let today: LocalDay
    let todayMetrics: DailyHealthMetrics?
    /// Manual and Health weights merged per day (`WeightReconciler`).
    let dayWeights: [DayWeight]
    let weight: WeightSummary?
    let bodyFat: BodyFatValue?
    let restingHR: BaselineComparison?
    let hrv: BaselineComparison?
    let water: WaterProgress
    /// Today's drinks logged in Vitalion, in time order.
    let hydrationIntakes: [FluidIntake]
    /// When Apple Health says the user woke up today.
    let wokeAt: Date?
    let hydrationSettings: HydrationSettings
    /// The hydration goal of each sparkline day, from that day's weight trend.
    let hydrationGoals: [LocalDay: Double]
    let totals: Nutrients
    let target: Target?
    let stepGoal: Int
    let sleepGoalMin: Int
    let goalMode: GoalMode
    /// Mean weight / body fat of the 7 days before the latest value (`WeeklyBand.average`); nil with too few days.
    let weeklyWeightKg: Double?
    let weeklyBodyFatPct: Double?
    /// 7-day series per tile (`DashboardSnapshot.sparklines`), also the ones that can't be drawn.
    let sparklines: [DashboardTile: Sparkline]
    /// Yesterday's and today's caffeine; the amount depends on the time, see `caffeineStatus(now:calendar:)`.
    let caffeine: CaffeineIntakes
    let caffeineSettings: CaffeineSettings
    /// Days in a row each goal was reached (steps, sleep, water), see `streak(for:)`.
    let streaks: [DashboardTile: Streak]

    init(_ data: DashboardData, calendar: Calendar = .current) {
        today = data.today
        let rows = data.metrics.map(\.metrics)
        todayMetrics = rows.first { $0.day == data.today }
        dayWeights = WeightReconciler.daily(
            health: rows,
            manual: data.manualWeights.map {
                ManualWeight(measuredAt: $0.measuredAt, kg: $0.kg, bodyFatPct: $0.bodyFatPct, enteredAt: $0.createdAt)
            },
            calendar: calendar,
        )
        weight = WeightTrend.summary(dayWeights, today: data.today)
        bodyFat = dayWeights.last { $0.bodyFatPct != nil && $0.day <= data.today }
            .flatMap { day in day.bodyFatPct.map { BodyFatValue(day: day.day, pct: $0) } }
        restingHR = MetricBaseline.compare(Self.values(rows, \.restingHR), today: data.today)
        hrv = MetricBaseline.compare(Self.values(rows, \.hrvSDNNms), today: data.today)
        hydrationIntakes = data.hydrationIntakes[data.today] ?? []
        water = WaterProgress(
            loggedMl: hydrationIntakes.reduce(0) { $0 + $1.ml },
            otherAppsMl: todayMetrics?.waterMl ?? 0,
            goalMl: data.hydrationGoalMl(on: data.today),
        )
        wokeAt = todayMetrics?.wokeAt
        hydrationSettings = data.hydrationSettings
        hydrationGoals = Dictionary(uniqueKeysWithValues: (0 ..< Sparkline.days).map { offset in
            let day = data.today.adding(days: -offset)
            return (day, data.hydrationGoalMl(on: day))
        })
        totals = data.totals
        target = data.target
        stepGoal = data.stepGoal
        sleepGoalMin = data.sleepGoalMin
        goalMode = data.goalMode
        var kgByDay: [LocalDay: Double] = [:]
        var fatByDay: [LocalDay: Double] = [:]
        for weight in dayWeights {
            kgByDay[weight.day] = weight.kg
            fatByDay[weight.day] = weight.bodyFatPct
        }
        weeklyWeightKg = weight.flatMap { WeeklyBand.average(kgByDay, before: $0.latest.day) }
        weeklyBodyFatPct = bodyFat.flatMap { WeeklyBand.average(fatByDay, before: $0.day) }
        sparklines = Self.sparklines(data: data, rows: rows, dayWeights: dayWeights)
        caffeine = data.caffeine
        caffeineSettings = data.caffeineSettings
        streaks = Self.streaks(data: data, rows: rows)
    }

    /// Today's hydration at `now`: totals, pace, gaps and status.
    func hydrationDay(now: Date, calendar: Calendar = .current) -> HydrationDay {
        HydrationDayBuilder.make(
            day: today, intakes: hydrationIntakes, otherAppsMl: water.otherAppsMl, wokeAt: wokeAt,
            settings: hydrationSettings, goalMl: water.goalMl, now: now, calendar: calendar,
        )
    }

    /// Caffeine at `now`: the amount in the body, today's total, the sleep outlook.
    func caffeineStatus(now: Date, calendar: Calendar = .current) -> CaffeineStatus {
        CaffeineStatus(intakes: caffeine, settings: caffeineSettings, today: today, now: now, calendar: calendar)
    }

    /// The tile's 7-day chart, nil when there are fewer than two days to draw or the tile has none.
    /// Total energy without a total today (only one part known) has none either: a chart of totals next to a
    /// partial value would read as if it were one of them.
    func sparkline(for tile: DashboardTile) -> Sparkline? {
        if tile == .totalEnergy, energyBurned?.totalKcal == nil {
            return nil
        }
        return sparklines[tile].flatMap { $0.isDrawable ? $0 : nil }
    }

    var steps: Int? {
        todayMetrics?.steps
    }

    /// Today's active and resting energy; nil when neither is known.
    var energyBurned: EnergyBurned? {
        let burned = EnergyBurned(activeKcal: todayMetrics?.activeKcal, restingKcal: todayMetrics?.basalKcal)
        return burned.hasValue ? burned : nil
    }

    /// Last night's minutes on the tile: asleep, or in bed when that is all Health has.
    var sleepMinutes: Int? {
        sleep?.asleepMin ?? sleep?.inBedMin
    }

    /// Last night (the night ending today).
    var sleep: SleepValue? {
        guard let metrics = todayMetrics, metrics.hasValue(.sleep) else { return nil }
        return SleepValue(
            asleepMin: metrics.sleepAsleepMin, inBedMin: metrics.sleepInBedMin, coreMin: metrics.sleepCoreMin,
            deepMin: metrics.sleepDeepMin, remMin: metrics.sleepRemMin, awakeMin: metrics.sleepAwakeMin,
        )
    }

    func hasValue(_ tile: DashboardTile) -> Bool {
        switch tile {
        case .energy, .water, .caffeine: true
        case .steps: steps != nil
        case .sleep: sleep != nil
        case .weight: weight != nil
        case .bodyFat: bodyFat != nil
        case .totalEnergy: energyBurned != nil
        case .restingHeartRate: restingHR != nil
        case .hrv: hrv != nil
        }
    }

    func state(of tile: DashboardTile, access: HealthAccess, isFirstSync: Bool) -> TileState {
        TileState.resolve(hasValue: hasValue(tile), usesHealth: tile.usesHealth, access: access, isFirstSync: isFirstSync)
    }

    private static func values(_ rows: [DailyHealthMetrics], _ key: KeyPath<DailyHealthMetrics, Double?>) -> [LocalDay: Double] {
        var result: [LocalDay: Double] = [:]
        for row in rows {
            if let value = row[keyPath: key] {
                result[row.day] = value
            }
        }
        return result
    }
}

// MARK: - Detail history

/// One day in a tile's detail list.
struct TileHistoryRow: Equatable, Identifiable {
    var day: LocalDay
    /// nil: no value that day.
    var value: String?
    var detail: String?
    /// Hydration only: the day's total and that day's goal, which colour the value.
    var amountMl: Double?
    var goalMl: Double?

    var id: LocalDay {
        day
    }
}

/// The last days of one tile, newest first (the detail screen; charts come in phase 3).
enum TileHistory {
    static let days = 14

    /// - Parameters:
    ///   - kcalByDay: diary energy per day (only for `.energy`).
    ///   - loggedFluidByDay: every drink logged in Vitalion per day — water, diary drinks, caffeine drinks (only
    ///     for `.water`).
    ///   - caffeineByDay: caffeine per day, quick-adds and diary (only for `.caffeine`).
    static func rows(
        for tile: DashboardTile,
        data: DashboardData,
        kcalByDay: [LocalDay: Double] = [:],
        loggedFluidByDay: [LocalDay: Double] = [:],
        caffeineByDay: [LocalDay: Double] = [:],
        energyUnit: EnergyUnit = .kcal,
        calendar: Calendar = .current,
    ) -> [TileHistoryRow] {
        let snapshot = DashboardSnapshot(data, calendar: calendar)
        let metrics = Dictionary(data.metrics.map { ($0.day, $0.metrics) }) { first, _ in first }
        let weights = Dictionary(snapshot.dayWeights.map { ($0.day, $0) }) { first, _ in first }
        var weightByDay: [LocalDay: Double] = [:]
        for (day, weight) in weights {
            if let kg = weight.kg {
                weightByDay[day] = kg
            }
        }
        let trend = WeightTrend.trendByDay(weightByDay, through: data.today)
        return (0 ..< days).map { offset in
            let day = data.today.adding(days: -offset)
            let row = metrics[day]
            switch tile {
            case .energy:
                let kcal = kcalByDay[day]
                return TileHistoryRow(day: day, value: kcal.map { energyUnit.format($0) })
            case .steps:
                return TileHistoryRow(day: day, value: row?.steps.map { "\($0.formatted()) steps" })
            case .sleep:
                let asleep = row?.sleepAsleepMin ?? row?.sleepInBedMin
                return TileHistoryRow(day: day, value: asleep.map(DashboardFormat.duration), detail: row.flatMap(DashboardFormat.stages))
            case .weight:
                let weight = weights[day]
                let kg = weight?.kg
                return TileHistoryRow(
                    day: day,
                    value: kg.map(DashboardFormat.kg),
                    detail: kg == nil ? nil : [
                        trend[day].map { "Trend \(DashboardFormat.kg($0))" },
                        weight?.isManual == true ? "Entered in Vitalion" : nil,
                    ].compactMap(\.self).joined(separator: " · "),
                )
            case .bodyFat:
                return TileHistoryRow(day: day, value: weights[day]?.bodyFatPct.map(DashboardFormat.percent))
            case .totalEnergy:
                let burned = EnergyBurned(activeKcal: row?.activeKcal, restingKcal: row?.basalKcal)
                return TileHistoryRow(
                    day: day,
                    value: burned.totalKcal.map { energyUnit.format($0) },
                    detail: burned.hasValue ? burned.breakdown(energyUnit) : nil,
                )
            case .restingHeartRate:
                return TileHistoryRow(day: day, value: row?.restingHR.map(DashboardFormat.bpm))
            case .hrv:
                return TileHistoryRow(day: day, value: row?.hrvSDNNms.map(DashboardFormat.ms))
            case .water:
                return hydrationRow(day, totalMl: (loggedFluidByDay[day] ?? 0) + (row?.waterMl ?? 0), data: data)
            case .caffeine:
                let mg = caffeineByDay[day] ?? 0
                return TileHistoryRow(
                    day: day,
                    value: mg > 0 ? CaffeineStatus.mg(mg) : nil,
                    detail: CaffeineLevel.isOverLimit(totalMg: mg, limitMg: data.caffeineSettings.dailyLimitMg)
                        ? "Over the daily \(CaffeineStatus.mg(data.caffeineSettings.dailyLimitMg))" : nil,
                )
            }
        }
    }

    /// Every drink plus other apps' water, against that day's own goal: "1,840 ml" "of 2,400 ml".
    private static func hydrationRow(_ day: LocalDay, totalMl: Double, data: DashboardData) -> TileHistoryRow {
        guard totalMl > 0 else { return TileHistoryRow(day: day) }
        let goal = data.hydrationGoalMl(on: day)
        return TileHistoryRow(
            day: day, value: DashboardFormat.ml(totalMl), detail: "of \(DashboardFormat.ml(goal))", amountMl: totalMl, goalMl: goal,
        )
    }
}

// MARK: - Formatting

enum DashboardFormat {
    /// "7h 5min", "8h", "45min" (#72).
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(rest)min" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)min"
    }

    /// "Core 3h 30min · Deep 1h 15min · REM 1h 40min · Awake 10min"; nil without stages.
    static func stages(_ metrics: DailyHealthMetrics) -> String? {
        let parts: [(String, Int?)] = [
            ("Core", metrics.sleepCoreMin), ("Deep", metrics.sleepDeepMin), ("REM", metrics.sleepRemMin), ("Awake", metrics.sleepAwakeMin),
        ]
        let text = parts.compactMap { name, minutes in minutes.map { "\(name) \(duration($0))" } }
        return text.isEmpty ? nil : text.joined(separator: " · ")
    }

    static func kg(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) kg"
    }

    /// "−0.4 kg", "+0.2 kg", "±0.0 kg".
    static func kgChange(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : "±"
        return "\(sign)\(abs(rounded).formatted(.number.precision(.fractionLength(1)))) kg"
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) %"
    }

    static func bpm(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) bpm"
    }

    static func ms(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) ms"
    }

    static func ml(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) ml"
    }
}
