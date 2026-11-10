import Core
import Foundation
import HealthKitClient
import Persistence

extension SettingKey {
    /// `DashboardLayout`: tile order and hidden tiles (backlog #28).
    static let dashboardLayout = "dashboardLayout"
    /// The daily step goal (`StepGoal`, #63).
    static let stepGoal = "stepGoal"
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
                + "7-day average can be a sign of stress, poor sleep, alcohol or an illness coming on. Compare it with "
                + "your own baseline rather than with other people."
        case .hrv:
            "Heart rate variability (HRV) is how much the time between heartbeats varies, in milliseconds (SDNN), "
                + "measured mostly while you sleep. A higher value than your usual generally means you are well "
                + "recovered; a lower one can follow hard training, stress, short sleep, alcohol or illness. HRV is "
                + "very individual, so compare it with your own 7- and 30-day averages, not with other people."
        case .steps, .sleep, .weight, .bodyFat:
            "Days without a value had no data in Apple Health — or Nutrilog may not have permission to read it."
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

// MARK: - Step goal

/// The daily step goal and how a day compares with it (#63).
enum StepGoal {
    static let defaultSteps = 10000
    static let validRange = 1000 ... 50000
    static let step = 500
    /// A day at or above this share of the goal is "near" it.
    static let nearShare = 0.8

    enum Band: Equatable {
        /// At or above the goal.
        case reached
        /// Below the goal, but at least `nearShare` of it.
        case near
        /// Well below the goal.
        case far
    }

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
