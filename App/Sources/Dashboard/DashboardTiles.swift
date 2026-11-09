import Core
import Foundation
import HealthKitClient
import Persistence

extension SettingKey {
    /// `DashboardLayout`: tile order and hidden tiles (backlog #28).
    static let dashboardLayout = "dashboardLayout"
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
    case activeEnergy
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
        case .activeEnergy: "Active energy"
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
        case .activeEnergy: "bolt.heart"
        case .restingHeartRate: "heart"
        case .hrv: "waveform.path.ecg"
        case .water: "drop"
        }
    }

    /// Wide tiles take a full row; the others are paired two per row.
    var isWide: Bool {
        switch self {
        case .energy, .sleep, .water: true
        default: false
        }
    }

    /// False for tiles that never depend on Health (the diary's calories).
    var usesHealth: Bool {
        self != .energy
    }
}

// MARK: - Layout

/// Order and visibility of the tiles, persisted in the `setting` table. Stored as raw strings so a value from a newer
/// version (an unknown tile) is skipped instead of breaking the whole layout, and tiles added in a later version are
/// appended (visible) at the end.
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

    /// Drops duplicates and appends tiles missing from `order`.
    private mutating func normalize() {
        var seen = Set<DashboardTile>()
        order = order.filter { seen.insert($0).inserted }
        order += DashboardTile.allCases.filter { !seen.contains($0) }
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

// MARK: - Tile state

/// What the app knows about Health access. Read access is opaque: after the user answered, a type without data may
/// be denied or simply empty, and the tile says so (`HealthKitClient.noDataMessage`).
enum HealthAccess: Equatable {
    /// No Health store on this device.
    case unavailable
    /// The user has not been asked yet.
    case notRequested
    /// The user answered the permission sheet (or Health could not tell).
    case requested

    init(isAvailable: Bool, status: HealthAuthorizationRequestStatus) {
        if !isAvailable {
            self = .unavailable
        } else if status == .shouldRequest {
            self = .notRequested
        } else {
            self = .requested
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
