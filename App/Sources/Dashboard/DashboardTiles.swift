import Core
import Foundation
import HealthKitClient
import Persistence

extension SettingKey {
    /// `DashboardLayout`: tile order and hidden tiles (backlog #28).
    static let dashboardLayout = "dashboardLayout"
    /// The daily step goal (`StepGoal`, #63).
    static let stepGoal = "stepGoal"
    /// The nightly sleep goal in minutes (`SleepGoal`, #72).
    static let sleepGoal = "sleepGoal"
}

extension AppEnvironment {
    /// Manual weights (FR-42, backlog #29). Health-sourced weights are in `dailyMetrics`.
    var weights: WeightRepository? {
        db.map { WeightRepository($0, clock: clock) }
    }
}

// MARK: - Tiles

/// The tiles of the Today dashboard (FR-41, backlog #28).
/// The case order is the default layout: wide tiles first, then narrow ones in pairs.
enum DashboardTile: String, CaseIterable, Codable, Identifiable, Hashable {
    case energy
    case water
    case sleep
    case weight
    case bodyFat
    case steps
    case totalEnergy
    case restingHeartRate
    case hrv

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .energy: "Calories"
        case .steps: "Steps"
        case .sleep: "Sleep"
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .totalEnergy: "Total energy"
        case .restingHeartRate: "Resting heart rate"
        case .hrv: "HRV"
        case .water: "Water"
        }
    }

    var systemImage: String {
        switch self {
        case .energy: "flame"
        case .steps: "figure.walk"
        case .sleep: "bed.double"
        case .weight: "scalemass"
        case .bodyFat: "percent"
        case .totalEnergy: "flame.circle"
        case .restingHeartRate: "heart"
        case .hrv: "waveform.path.ecg"
        case .water: "drop"
        }
    }

    /// Wide tiles take a full row; the others are paired two per row.
    var isWide: Bool {
        switch self {
        case .energy, .water: true
        default: false
        }
    }

    /// The text under the tile's detail list: what the metric is and how to read it (#67), or where missing days
    /// come from.
    var detailDescription: String? {
        switch self {
        case .energy, .water:
            nil
        case .totalEnergy:
            "Total energy is resting plus active energy from Apple Health: resting is what your body burns just to "
                + "keep going, active is what movement and exercise add. A day with only one of them has no total."
        case .restingHeartRate:
            "Resting heart rate is how many times your heart beats per minute while you are awake, calm and haven't "
                + "moved for a while. A lower value usually goes with better fitness; a value clearly above your own "
                + "average can be a sign of stress, poor sleep, alcohol or an illness coming on. Compare it with "
                + "your own baseline rather than with other people. The value is green at or below your 30-day "
                + "average, orange slightly above it and red more than 5% above."
        case .hrv:
            "Heart rate variability (HRV) is how much the time between heartbeats varies, in milliseconds (SDNN), "
                + "measured mostly while you sleep. A higher value than your usual generally means you are well "
                + "recovered; a lower one can follow hard training, stress, short sleep, alcohol or illness. HRV is "
                + "very individual, so compare it with your own 7- and 30-day averages, not with other people. The value is green at or above "
                + "your 30-day average, orange slightly below it and red more than 10% below."
        case .steps, .sleep, .weight, .bodyFat:
            "Days without a value had no data in Apple Health — or Vitalion may not have permission to read it."
        }
    }

    /// False for tiles that never depend on Health (the diary's calories).
    var usesHealth: Bool {
        self != .energy
    }
}

// MARK: - Layout

/// Order and visibility of the tiles, persisted in the `setting` table. Stored as raw strings so a value from a newer
/// version (an unknown tile) is skipped instead of breaking the whole layout, and tiles added in a later version show
/// up (visible) in a saved layout: right after the tile they follow in the default order, or at the end.
struct DashboardLayout: Equatable, Codable {
    var order: [DashboardTile]
    var hidden: Set<DashboardTile>

    static let `default` = DashboardLayout(order: DashboardTile.allCases, hidden: [])

    init(order: [DashboardTile], hidden: Set<DashboardTile>) {
        self.order = order
        self.hidden = hidden
        normalize()
    }

    var visible: [DashboardTile] {
        order.filter { !hidden.contains($0) }
    }

    func isVisible(_ tile: DashboardTile) -> Bool {
        !hidden.contains(tile)
    }

    mutating func setVisible(_ tile: DashboardTile, _ visible: Bool) {
        if visible {
            hidden.remove(tile)
        } else {
            hidden.insert(tile)
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }

    /// Reorders the visible tiles (offsets into `visible`); hidden tiles follow them.
    mutating func moveVisible(fromOffsets source: IndexSet, toOffset destination: Int) {
        var shown = visible
        shown.move(fromOffsets: source, toOffset: destination)
        order = shown + order.filter { hidden.contains($0) }
    }

    /// Shows a hidden tile as the last visible one.
    mutating func show(_ tile: DashboardTile) {
        guard hidden.remove(tile) != nil else { return }
        order = visible.filter { $0 != tile } + [tile] + order.filter { hidden.contains($0) }
    }

    /// Visible tiles grouped into rows: a wide tile alone, narrow tiles in pairs (a narrow tile followed by a wide one
    /// or ending the list sits alone).
    var rows: [[DashboardTile]] {
        var rows: [[DashboardTile]] = []
        var pending: DashboardTile?
        for tile in visible {
            if tile.isWide {
                if let narrow = pending {
                    rows.append([narrow])
                    pending = nil
                }
                rows.append([tile])
            } else if let narrow = pending {
                rows.append([narrow, tile])
                pending = nil
            } else {
                pending = tile
            }
        }
        if let pending {
            rows.append([pending])
        }
        return rows
    }

    /// Drops duplicates and adds tiles missing from `order` (a tile added in an update): after the nearest tile that
    /// precedes it in the default order (Total energy after Steps), or at the end when none does. A tile that no
    /// longer exists (Active energy, merged into Total energy in #66) is skipped when decoding.
    private mutating func normalize() {
        var seen = Set<DashboardTile>()
        order = order.filter { seen.insert($0).inserted }
        let catalog = DashboardTile.allCases
        for (index, tile) in catalog.enumerated() where !seen.contains(tile) {
            let current = order
            let anchor = catalog[..<index].reversed().lazy.compactMap { current.firstIndex(of: $0) }.first
            order.insert(tile, at: anchor.map { $0 + 1 } ?? order.endIndex)
            seen.insert(tile)
        }
    }

    // MARK: Codable (lenient)

    private enum CodingKeys: String, CodingKey {
        case order, hidden
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        let hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        self.init(order: order.compactMap(DashboardTile.init(rawValue:)), hidden: Set(hidden.compactMap(DashboardTile.init(rawValue:))))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order.map(\.rawValue), forKey: .order)
        try container.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }

    // MARK: Persistence

    /// The saved layout, or the default when none is saved or it can't be read.
    static func load(from settings: ProfileRepository) -> DashboardLayout {
        (try? settings.setting(SettingKey.dashboardLayout, as: DashboardLayout.self)) ?? .default
    }

    func save(to settings: ProfileRepository) throws {
        try settings.setSetting(SettingKey.dashboardLayout, self)
    }
}

// MARK: - Water quick-add sizes

/// The water quick-add buttons (FR-46): configurable sizes in ml, persisted in `SettingKey.waterQuickAddSizes`.
enum WaterQuickAdd {
    static let defaultSizes = [250, 500]
    static let maximumCount = 4
    static let validRange = 50 ... 2000

    /// Sorted, unique, in range, at most `maximumCount`; the defaults when nothing usable is left.
    static func normalized(_ sizes: [Int]) -> [Int] {
        let valid = Array(Set(sizes.filter { validRange.contains($0) })).sorted()
        return valid.isEmpty ? defaultSizes : Array(valid.prefix(maximumCount))
    }

    /// The size "Add size" adds: 250 ml above the largest (capped), else the first free 50 ml step; nil when the
    /// list is full or every step is taken.
    static func nextSize(after sizes: [Int]) -> Int? {
        guard sizes.count < maximumCount else { return nil }
        let preferred = min((sizes.max() ?? 0) + 250, validRange.upperBound)
        if !sizes.contains(preferred) {
            return preferred
        }
        return stride(from: validRange.lowerBound, through: validRange.upperBound, by: 50).first { !sizes.contains($0) }
    }

    /// One stepper tap on a size: `value + delta`, skipping over sizes in `others` to the next free step in the same
    /// direction, so two buttons never merge; `value` itself when no free step is left inside `validRange` (or
    /// `value` is outside it, which saved sizes never are).
    static func stepped(_ value: Int, by delta: Int, among others: [Int]) -> Int {
        guard delta != 0, validRange.contains(value), delta.magnitude <= validRange.count.magnitude else { return value }
        var candidate = value + delta
        while validRange.contains(candidate) {
            if !others.contains(candidate) {
                return candidate
            }
            candidate += delta
        }
        return value
    }

    static func sizes(from settings: ProfileRepository) -> [Int] {
        normalized((try? settings.setting(SettingKey.waterQuickAddSizes, as: [Int].self)) ?? defaultSizes)
    }

    @discardableResult
    static func save(_ sizes: [Int], to settings: ProfileRepository) throws -> [Int] {
        let normalized = normalized(sizes)
        try settings.setSetting(SettingKey.waterQuickAddSizes, normalized)
        return normalized
    }
}

// MARK: - Goal bands

/// How a value compares with its goal or baseline; drawn green, orange and red (`GoalColor`).
enum GoalBand: Equatable {
    /// At the goal or better.
    case reached
    /// Close to it.
    case near
    /// Well off it.
    case far
}

// MARK: - Step goal

/// The daily step goal and how a day compares with it (#63).
enum StepGoal {
    static let defaultSteps = 10000
    static let validRange = 1000 ... 50000
    static let step = 500
    /// A day at or above this share of the goal is "near" it.
    static let nearShare = 0.8

    typealias Band = GoalBand

    /// Near: below the goal, but at least `nearShare` of it.
    static func band(steps: Double, goal: Int) -> Band {
        guard goal > 0 else { return .reached }
        if steps >= Double(goal) {
            return .reached
        }
        return steps >= Double(goal) * nearShare ? .near : .far
    }

    static func normalized(_ steps: Int) -> Int {
        min(max(steps, validRange.lowerBound), validRange.upperBound)
    }

    static func load(from settings: ProfileRepository) -> Int {
        normalized((try? settings.setting(SettingKey.stepGoal, as: Int.self)) ?? defaultSteps)
    }

    static func save(_ steps: Int, to settings: ProfileRepository) throws {
        try settings.setSetting(SettingKey.stepGoal, normalized(steps))
    }
}

// MARK: - Sleep goal

/// The nightly sleep goal and how a night compares with it (#72).
enum SleepGoal {
    static let defaultMinutes = 8 * 60
    static let validRange = 4 * 60 ... 12 * 60
    static let step = 15
    /// A night at most this many minutes short of the goal is "near" it.
    static let nearMinutes = 60

    static func band(minutes: Double, goal: Int) -> GoalBand {
        guard goal > 0 else { return .reached }
        if minutes >= Double(goal) {
            return .reached
        }
        return minutes >= Double(goal - nearMinutes) ? .near : .far
    }

    static func normalized(_ minutes: Int) -> Int {
        min(max(minutes, validRange.lowerBound), validRange.upperBound)
    }

    static func load(from settings: ProfileRepository) -> Int {
        normalized((try? settings.setting(SettingKey.sleepGoal, as: Int.self)) ?? defaultMinutes)
    }

    static func save(_ minutes: Int, to settings: ProfileRepository) throws {
        try settings.setSetting(SettingKey.sleepGoal, normalized(minutes))
    }
}

// MARK: - Baseline bands

/// How today's HRV or resting heart rate compares with the 30-day average (#74).
enum BaselineBand {
    /// Within half a percent counts as the average (the tile then says "In line with your 30-day average").
    static let tolerance = 0.005
    /// HRV down to 10% below the average is "slightly below"; HRV swings a lot from day to day.
    static let hrvNear = 0.10
    /// Resting heart rate up to 5% above the average is "slightly above".
    static let restingHRNear = 0.05

    /// HRV: higher is better. nil without a 30-day average.
    static func hrv(_ comparison: BaselineComparison) -> GoalBand? {
        comparison.deviation.map { band(shortfall: -$0, near: hrvNear) }
    }

    /// Resting heart rate: lower is better. nil without a 30-day average.
    static func restingHR(_ comparison: BaselineComparison) -> GoalBand? {
        comparison.deviation.map { band(shortfall: $0, near: restingHRNear) }
    }

    /// `shortfall`: how far the value is on the wrong side of the average, as a share of it.
    private static func band(shortfall: Double, near: Double) -> GoalBand {
        if shortfall < tolerance {
            return .reached
        }
        return shortfall <= near ? .near : .far
    }
}

// MARK: - Weekly bands

/// How the latest weight or body fat compares with the week before it (owner feedback).
enum WeeklyBand {
    /// The average needs at least this many of the 7 days before the latest value.
    static let minimumDays = 3
    /// Weight up to this many kg on the wrong side of the average is "slightly" off.
    static let weightNearKg = 0.5
    /// Body fat up to this many percentage points above the average is "slightly above".
    static let bodyFatNearPoints = 0.5

    /// The mean of the values on the 7 days before `day`; nil with fewer than `minimumDays` of them.
    static func average(_ values: [LocalDay: Double], before day: LocalDay) -> Double? {
        let week = (1 ... 7).compactMap { values[day.adding(days: -$0)] }
        guard week.count >= minimumDays else { return nil }
        return week.reduce(0, +) / Double(week.count)
    }

    /// Losing: green at or below the average, orange slightly above, red far above. Gaining: the mirror image.
    /// Maintaining has no better direction, so no band.
    static func weight(kg: Double, average: Double, goal: GoalMode) -> GoalBand? {
        switch goal {
        case .lose: band(excess: kg - average, near: weightNearKg)
        case .gain: band(excess: average - kg, near: weightNearKg)
        case .maintain: nil
        }
    }

    /// Body fat: green at or below the average, orange slightly above, red far above.
    static func bodyFat(pct: Double, average: Double) -> GoalBand {
        band(excess: pct - average, near: bodyFatNearPoints)
    }

    /// `excess`: how far the value is on the wrong side of the average.
    private static func band(excess: Double, near: Double) -> GoalBand {
        if excess <= 0 {
            return .reached
        }
        return excess <= near ? .near : .far
    }
}

/// Water against its daily goal: green at the goal, orange from `nearShare` of it, red below.
enum WaterGoal {
    static let nearShare = 0.8

    static func band(ml: Double, goalMl: Double) -> GoalBand {
        guard goalMl > 0, ml < goalMl else { return .reached }
        return ml >= goalMl * nearShare ? .near : .far
    }
}

// MARK: - Tile state

/// What the app knows about Health access. Read access is opaque: after the user answered, a type without data may
/// be denied or simply empty, and the tile says so (`HealthKitClient.noDataMessage`).
enum HealthAccess: Equatable {
    /// No Health store on this device.
    case unavailable
    /// Not known yet (the status is being read).
    case checking
    /// The user has not been asked yet.
    case notRequested
    /// The user answered the permission sheet, or connected before and an update added types to allow (Health then
    /// says `.shouldRequest` again, but the user is not "unconnected"), or Health could not tell.
    case requested

    /// - Parameters:
    ///   - status: `HealthSyncService.requestStatus`; nil while it is being read.
    ///   - isConnected: `HealthSyncService.isConnected` (answered, or a full sync completed before).
    init(isAvailable: Bool, status: HealthAuthorizationRequestStatus?, isConnected: Bool) {
        if !isAvailable {
            self = .unavailable
        } else if isConnected {
            self = .requested
        } else if let status {
            self = status == .shouldRequest ? .notRequested : .requested
        } else {
            self = .checking
        }
    }
}

/// The state a tile shows.
enum TileState: Equatable {
    /// The first Health sync is still running and there is nothing to show yet.
    case loading
    /// Health has not been connected: offer to connect.
    case needsAccess
    /// No Health on this device.
    case unavailable
    /// Nothing found — not recorded, or read access denied (indistinguishable); the message says which to check.
    case noData(String)
    /// The tile has a value.
    case ready

    static let unavailableMessage = "Apple Health isn't available on this device"
    static let needsAccessMessage = "Connect Apple Health to see this"

    /// A value always shows. Without one: no Health → unavailable; not asked → needs access; first sync running →
    /// loading; otherwise "No data found — check Health permissions" (denied and empty look the same).
    static func resolve(hasValue: Bool, usesHealth: Bool = true, access: HealthAccess, isFirstSync: Bool) -> TileState {
        if hasValue || !usesHealth {
            return .ready
        }
        switch access {
        case .unavailable: return .unavailable
        case .checking: return .loading
        case .notRequested: return .needsAccess
        case .requested: return isFirstSync ? .loading : .noData(HealthKitClient.noDataMessage)
        }
    }

    var message: String? {
        switch self {
        case .loading: "Reading Apple Health…"
        case .needsAccess: Self.needsAccessMessage
        case .unavailable: Self.unavailableMessage
        case let .noData(message): message
        case .ready: nil
        }
    }
}
