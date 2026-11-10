import Core
import Foundation
import Persistence

/// What the App Intents do (FR-71, backlog #40), separate from the AppIntents types so it can be unit-tested.
/// Every write goes through the same repositories as the app, so the entries are queued for Apple Health like any
/// other, and the Health queue is drained before the intent returns.
@MainActor
struct IntentActions {
    enum Failure: Error, CustomLocalizedStringResourceConvertible, Equatable {
        case databaseUnavailable
        case foodNotFound
        case invalidAmount
        case noMealSlot

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .databaseUnavailable: "Nutrilog's data isn't available right now. Open the app and try again."
            case .foodNotFound: "That food is no longer in Nutrilog."
            case .invalidAmount: "The amount must be greater than zero."
            case .noMealSlot: "There is no active meal to log to."
            }
        }
    }

    let environment: AppEnvironment
    var calendar: Calendar = .current

    /// The meal slot for the current time of day (the same suggestion the app uses).
    func currentSlot() throws -> MealSlot {
        guard let diary = environment.diary else { throw Failure.databaseUnavailable }
        let slots = try diary.mealSlots()
        let hour = calendar.component(.hour, from: environment.clock.now())
        let id = MealSlotSuggestion.slot(
            forHour: hour, among: slots.map { MealSlotSuggestion.Slot(id: $0.id, startHour: $0.defaultStartHour, sortOrder: $0.sortOrder) },
        )
        guard let slot = slots.first(where: { $0.id == id }) ?? slots.first else { throw Failure.noMealSlot }
        return slot
    }

    /// Logs a favorite food: `amount` in g/ml, or the food's usual quantity (last used, else its default serving).
    func logFood(id: String, amount: Double?) async throws -> String {
        environment.refreshToday()
        guard let foods = environment.foods, let diary = environment.diary else { throw Failure.databaseUnavailable }
        guard let detail = try foods.detail(id: id), detail.food.deletedAt == nil else { throw Failure.foodNotFound }
        let quantity: Quantity
        var servingID: String?
        if let amount {
            guard amount > 0, amount.isFinite, !detail.isPerServingPlaceholder else { throw Failure.invalidAmount }
            quantity = .base(amount)
        } else {
            let initial = QuantitySheet.initialLogQuantity(detail)
            quantity = initial.quantity
            servingID = initial.servingID ?? detail.food.lastServingID
        }
        let slot = try currentSlot()
        let entry = try diary.log(food: detail.food, quantity: quantity, servingID: servingID, slotID: slot.id, day: environment.today)
        await finishWrite()
        let amountText = Format.amount(grams: entry.grams, unit: detail.food.baseUnit, servingLabel: entry.servingLabel)
        return "Logged \(detail.food.name), \(amountText), \(environment.energyUnit.format(entry.kcal)), to \(slot.name)."
    }

    /// Quick-adds `kcal` (no macros) to the current meal.
    func quickAdd(kcal: Double, name: String?) async throws -> String {
        environment.refreshToday()
        guard let diary = environment.diary else { throw Failure.databaseUnavailable }
        guard kcal > 0, kcal.isFinite, kcal <= 20000 else { throw Failure.invalidAmount }
        let slot = try currentSlot()
        try diary.logQuickAdd(
            name: name,
            nutrients: Nutrients(kcal: kcal, proteinG: 0, carbsG: 0, fatG: 0),
            slotID: slot.id,
            day: environment.today,
        )
        await finishWrite()
        return try "Added \(Int(kcal.rounded())) kcal to \(slot.name). \(remainingSentence())"
    }

    /// Logs water (ml) for today.
    func logWater(ml: Double) async throws -> String {
        environment.refreshToday()
        guard let water = environment.water, let profiles = environment.profiles else { throw Failure.databaseUnavailable }
        guard ml > 0, ml.isFinite, ml <= 5000 else { throw Failure.invalidAmount }
        try water.add(ml: ml, day: environment.today)
        await finishWrite()
        let other = (try? environment.dailyMetrics?.metrics(on: environment.today)?.waterMl) ?? 0
        let total = try water.totalMl(for: environment.today) + other
        let goal = try profiles.profile().waterGoalMl
        return "Logged \(Int(ml.rounded())) ml of water. \(Int(total.rounded())) of \(Int(goal.rounded())) ml today."
    }

    /// Today's remaining energy against the target; `remainingKcal` is nil without a target.
    func remaining() throws -> (remainingKcal: Double?, consumedKcal: Double, targetKcal: Double?) {
        environment.refreshToday()
        guard let diary = environment.diary, let profiles = environment.profiles else { throw Failure.databaseUnavailable }
        let consumed = try diary.totals(for: environment.today).kcal
        let target = try profiles.target(on: environment.today)?.kcal
        return (target.map { $0 - consumed }, consumed, target)
    }

    /// "You have 640 kcal left today." / "You are 120 kcal over your target today." / "You've had 1,400 kcal today…".
    func remainingSentence() throws -> String {
        let unit = environment.energyUnit
        let status = try remaining()
        guard let left = status.remainingKcal else {
            return "You've had \(unit.format(status.consumedKcal)) today. Set a calorie target in Nutrilog to see what's left."
        }
        return left >= 0
            ? "You have \(unit.format(left)) left today."
            : "You are \(unit.format(-left)) over your target today."
    }

    /// Favorites for the Shortcuts food picker.
    func favorites() throws -> [Food] {
        guard let foods = environment.foods else { throw Failure.databaseUnavailable }
        return try foods.favorites()
    }

    func foods(ids: [String]) throws -> [Food] {
        guard let foods = environment.foods else { throw Failure.databaseUnavailable }
        return try ids.compactMap { try foods.food(id: $0) }.filter { $0.deletedAt == nil }
    }

    /// After a write: send it to Apple Health now (the app may be in the background) and update the widgets.
    private func finishWrite() async {
        await environment.healthWrites?.drain()
        environment.widgetDataDidChange()
    }
}
