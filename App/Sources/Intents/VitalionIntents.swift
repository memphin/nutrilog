import AppIntents
import Foundation
import Persistence

// Siri / Shortcuts actions (FR-71, backlog #40). None of them opens the app: the system starts it in the
// background, `VitalionApp.init` builds the environment, and the intent works on the same repositories.

/// A favorite food as a Shortcuts parameter.
struct FoodEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food"
    static let defaultQuery = FavoriteFoodQuery()

    let id: String
    let name: String
    let brand: String?

    var displayRepresentation: DisplayRepresentation {
        if let brand, !brand.isEmpty {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(brand)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(_ food: Food) {
        id = food.id
        name = food.name
        brand = food.brand
    }
}

struct FavoriteFoodQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FoodEntity] {
        try VitalionIntentSupport.actions().foods(ids: identifiers).map(FoodEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FoodEntity] {
        try VitalionIntentSupport.actions().favorites().map(FoodEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [FoodEntity] {
        try VitalionIntentSupport.actions().favorites()
            .filter { $0.name.localizedStandardContains(string) || ($0.brand?.localizedStandardContains(string) ?? false) }
            .map(FoodEntity.init)
    }
}

@MainActor
enum VitalionIntentSupport {
    static func actions() throws -> IntentActions {
        guard let environment = AppEnvironment.shared else { throw IntentActions.Failure.databaseUnavailable }
        return IntentActions(environment: environment)
    }
}

struct LogFavoriteFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Favorite Food"
    static let description = IntentDescription(
        "Logs one of your favorite foods to the current meal. Without an amount, the amount you logged last is used.",
        categoryName: "Diary",
    )
    static let openAppWhenRun = false

    @Parameter(title: "Food")
    var food: FoodEntity

    @Parameter(title: "Amount (g or ml)", description: "Leave empty to use your usual amount.", inclusiveRange: (0.1, 5000))
    var amount: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$food)") {
            \.$amount
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await VitalionIntentSupport.actions().logFood(id: food.id, amount: amount)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct QuickAddCaloriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick-Add Calories"
    static let description = IntentDescription("Adds calories to the current meal without choosing a food.", categoryName: "Diary")
    static let openAppWhenRun = false

    @Parameter(title: "Calories (kcal)", inclusiveRange: (1, 20000), requestValueDialog: "How many calories?")
    var calories: Double

    @Parameter(title: "Name", description: "Optional, e.g. “Lunch out”.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Quick-add \(\.$calories) kcal") {
            \.$name
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await VitalionIntentSupport.actions().quickAdd(kcal: calories, name: name)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct RemainingCaloriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Remaining Calories"
    static let description = IntentDescription(
        "Tells you how many calories are left today. In a shortcut it returns the number in kcal.", categoryName: "Diary",
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let actions = try VitalionIntentSupport.actions()
        let status = try actions.remaining()
        return try .result(value: (status.remainingKcal ?? 0).rounded(), dialog: IntentDialog(stringLiteral: actions.remainingSentence()))
    }
}

struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Water"
    static let description = IntentDescription(
        "Logs water for today (also written to the Health app) and tells you today's hydration from all drinks.",
        categoryName: "Hydration",
    )
    static let openAppWhenRun = false

    @Parameter(title: "Amount (ml)", default: 250, inclusiveRange: (1, 5000))
    var amount: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) ml of water")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await VitalionIntentSupport.actions().logWater(ml: amount)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct VitalionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RemainingCaloriesIntent(),
            phrases: [
                "How many calories do I have left in \(.applicationName)",
                "Remaining calories in \(.applicationName)",
                "\(.applicationName) calories left",
            ],
            shortTitle: "Calories left",
            systemImageName: "flame",
        )
        AppShortcut(
            intent: LogFavoriteFoodIntent(),
            phrases: [
                "Log \(\.$food) in \(.applicationName)",
                "Log a favorite in \(.applicationName)",
                "Add \(\.$food) to \(.applicationName)",
            ],
            shortTitle: "Log favorite",
            systemImageName: "star",
        )
        AppShortcut(
            intent: QuickAddCaloriesIntent(),
            phrases: [
                "Quick add calories in \(.applicationName)",
                "Add calories to \(.applicationName)",
            ],
            shortTitle: "Quick-add calories",
            systemImageName: "bolt",
        )
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Add water to \(.applicationName)",
            ],
            shortTitle: "Log water",
            systemImageName: "drop",
        )
    }
}
