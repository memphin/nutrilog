import OSLog
import Security
import SwiftUI

@main
struct VitalionApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = VitalionApp.makeEnvironment()
        _environment = State(initialValue: environment)
        AppEnvironment.shared = environment // App Intents run outside the view tree
        // Here rather than in a view: Health may launch the app in the background to deliver observer updates,
        // and the observer queries must be registered on every launch (backlog #26).
        environment.startHealthBackgroundWork()
        // Also before launching finishes: a tap on the hydration reminder's "+ 250 ml" launches the app in the
        // background and is delivered to this delegate.
        NotificationDelegate.install(environment: environment)
        environment.startHydrationReminders()
        Self.deleteLegacyUSDAKey()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }

    /// Removes the USDA API key users could once enter in Settings (now build-time only), which stayed in the
    /// Keychain. Idempotent: nothing to do once it is gone.
    static func deleteLegacyUSDAKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // The app's former name (Nutrilog), as the removed key store saved it.
            kSecAttrService as String: "hr.ivanjuric.nutrilog.usda-fdc",
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger(subsystem: "hr.ivanjuric.nutrilog", category: "keychain").error("Deleting the old USDA key failed: \(status)")
        }
    }

    @MainActor
    private static func makeEnvironment() -> AppEnvironment {
        #if DEBUG
            // `-uiSampleData` launches with an in-memory database and sample entries (screenshots, UI checks).
            if ProcessInfo.processInfo.arguments.contains("-uiSampleData") {
                return AppEnvironment.preview(sampleData: true, mealEstimator: AppleMealEstimator())
            }
        #endif
        return AppEnvironment.live()
    }
}
