import Foundation
import UserNotifications

/// Answers the notification center for the whole app (set at launch, before launching finishes, so the hydration
/// reminder's background action reaches it). Only the hydration reminder is handled here: its "+ 250 ml" action logs
/// water and its tap opens the Hydration detail. Every other notification (the weekly check-in) behaves as without a
/// delegate: not shown while the app is open, a tap just opens the app.
final class NotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate, Sendable {
    /// The notification center keeps its delegate weakly.
    @MainActor private static var installed: NotificationDelegate?

    private let addWater: @MainActor @Sendable () async -> Void
    private let openHydration: @MainActor @Sendable () -> Void

    init(addWater: @escaping @MainActor @Sendable () async -> Void, openHydration: @escaping @MainActor @Sendable () -> Void) {
        self.addWater = addWater
        self.openHydration = openHydration
    }

    /// Makes a delegate acting on `environment` the notification center's delegate.
    @MainActor
    static func install(environment: AppEnvironment) {
        let delegate = NotificationDelegate(
            addWater: { await environment.handleHydrationAddAction() },
            openHydration: { environment.openDashboardTile(.water) },
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
        case nil: break // dismissed, or not the hydration reminder
        }
    }

    /// How a notification arriving while the app is open is shown: only the hydration reminder is.
    static func presentationOptions(identifier: String) -> UNNotificationPresentationOptions {
        isHydrationReminder(identifier) ? [.banner, .sound] : []
    }

    /// What the response `actionIdentifier` to the notification `identifier` does; nil for anything but a tap or the
    /// add action on the hydration reminder.
    static func action(identifier: String, actionIdentifier: String) -> Action? {
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
