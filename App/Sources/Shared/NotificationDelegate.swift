import Core
import Foundation
import UserNotifications

/// Answers the notification center for the whole app (set at launch, before launching finishes, so the hydration
/// reminder's background action reaches it). The hydration reminder's "+ 250 ml" action logs water and its tap opens
/// the Hydration detail; a supplement reminder's "Taken" logs its doses, "Snooze" reminds again later and its tap opens
/// the diary of its day. Every other notification (the weekly check-in) behaves as without a delegate: not shown while
/// the app is open, a tap just opens the app.
final class NotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate, Sendable {
    /// The notification center keeps its delegate weakly.
    @MainActor private static var installed: NotificationDelegate?

    private let addWater: @MainActor @Sendable () async -> Void
    private let openHydration: @MainActor @Sendable () -> Void
    private let supplementAction: @MainActor @Sendable (Action) async -> Void

    init(
        addWater: @escaping @MainActor @Sendable () async -> Void,
        openHydration: @escaping @MainActor @Sendable () -> Void,
        supplementAction: @escaping @MainActor @Sendable (Action) async -> Void = { _ in },
    ) {
        self.addWater = addWater
        self.openHydration = openHydration
        self.supplementAction = supplementAction
    }

    /// Makes a delegate acting on `environment` the notification center's delegate.
    @MainActor
    static func install(environment: AppEnvironment) {
        let delegate = NotificationDelegate(
            addWater: { await environment.handleHydrationAddAction() },
            openHydration: { environment.openDashboardTile(.water) },
            supplementAction: { action in
                switch action {
                case let .supplementTaken(slot): await environment.handleSupplementTaken(slot)
                case let .supplementSnooze(slot): await environment.handleSupplementSnooze(slot)
                case let .openSupplements(day): environment.openDiary(on: day)
                case .addWater, .openHydration: break
                }
            },
        )
        installed = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// What a tap on a notification does.
    enum Action: Equatable {
        /// The hydration reminder's "+ 250 ml" action.
        case addWater
        /// A tap on the hydration reminder itself.
        case openHydration
        /// A supplement reminder's "Taken" action: logs the slot's open doses.
        case supplementTaken(SupplementSlot)
        /// A supplement reminder's "Snooze" action.
        case supplementSnooze(SupplementSlot)
        /// A tap on a supplement reminder: the diary of its day.
        case openSupplements(LocalDay)
    }

    // Main actor: the completion handler UIKit bridges these async methods to must be called on the main thread, so
    // they must not finish on a background executor after an await. (The `@preconcurrency` conformance lets the
    // notification center's non-Sendable arguments into the main actor: it calls its delegate on the main thread.)

    @MainActor
    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        Self.presentationOptions(identifier: notification.request.identifier)
    }

    @MainActor
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch Self.action(identifier: response.notification.request.identifier, actionIdentifier: response.actionIdentifier) {
        case .addWater: await addWater()
        case .openHydration: openHydration()
        case let action?: await supplementAction(action)
        case nil: break // dismissed, or not a reminder the app acts on
        }
    }

    /// How a notification arriving while the app is open is shown: only the hydration and supplement reminders are.
    static func presentationOptions(identifier: String) -> UNNotificationPresentationOptions {
        isHydrationReminder(identifier) || SupplementNotificationID.parse(identifier) != nil ? [.banner, .sound] : []
    }

    /// What the response `actionIdentifier` to the notification `identifier` does; nil for anything but a tap or the
    /// add action on the hydration reminder.
    static func action(identifier: String, actionIdentifier: String) -> Action? {
        if let slot = SupplementNotificationID.parse(identifier)?.slot {
            switch actionIdentifier {
            case LocalNotificationSupplementReminder.takenActionIdentifier: return .supplementTaken(slot)
            case LocalNotificationSupplementReminder.snoozeActionIdentifier: return .supplementSnooze(slot)
            case UNNotificationDefaultActionIdentifier: return .openSupplements(slot.day)
            default: return nil
            }
        }
        guard isHydrationReminder(identifier) else { return nil }
        switch actionIdentifier {
        case LocalNotificationHydrationReminder.addActionIdentifier: return .addWater
        case UNNotificationDefaultActionIdentifier: return .openHydration
        default: return nil
        }
    }

    static func isHydrationReminder(_ identifier: String) -> Bool {
        identifier == LocalNotificationHydrationReminder.identifier
    }
}
