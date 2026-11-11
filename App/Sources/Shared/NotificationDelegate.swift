import Foundation
import UserNotifications

/// Answers the notification center for the whole app (set at launch, before launching finishes, so the hydration
/// reminder's background action reaches it). Only the hydration reminder is handled here: its "+ 250 ml" action logs
/// water and its tap opens the Hydration detail. Every other notification (the weekly check-in) behaves as without a
/// delegate: not shown while the app is open, a tap just opens the app.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
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

    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        Self.isHydrationReminder(notification.request.identifier) ? [.banner, .sound] : []
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard Self.isHydrationReminder(response.notification.request.identifier) else { return }
        switch response.actionIdentifier {
        case LocalNotificationHydrationReminder.addActionIdentifier:
            await addWater()
        case UNNotificationDefaultActionIdentifier:
            await openHydration()
        default:
            break // dismissed
        }
    }

    static func isHydrationReminder(_ identifier: String) -> Bool {
        identifier == LocalNotificationHydrationReminder.identifier
    }
}
