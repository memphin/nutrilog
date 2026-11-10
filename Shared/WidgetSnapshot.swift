import Foundation

/// What the widgets show (FR-70, backlog #42): a small snapshot of today the app writes to the shared App Group
/// container after every change. The widget extension never opens the database.
struct WidgetSnapshot: Codable, Equatable {
    /// Identifiers keep the app's former name (Nutrilog): changing them would cut installed copies off from their data.
    static let appGroup = "group.hr.ivanjuric.nutrilog"
    static let key = "widgetSnapshot.v1"

    /// "YYYY-MM-DD" the numbers belong to; the widget shows an empty day once it is over.
    var day: String
    var kcal: Double
    var targetKcal: Double?
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var targetProteinG: Double?
    var targetCarbsG: Double?
    var targetFatG: Double?
    var steps: Int?
    var sleepMin: Int?
    var weightKg: Double?
    var waterMl: Double
    var waterGoalMl: Double
    /// "kcal" or "kJ".
    var energyUnit: String
    var updatedAt: Date

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}
