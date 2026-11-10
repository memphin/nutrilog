import SwiftUI

@main
struct NutrilogApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = NutrilogApp.makeEnvironment()
        _environment = State(initialValue: environment)
        AppEnvironment.shared = environment // App Intents run outside the view tree
        // Here rather than in a view: Health may launch the app in the background to deliver observer updates,
        // and the observer queries must be registered on every launch (backlog #26).
        environment.startHealthBackgroundWork()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }

    @MainActor
    private static func makeEnvironment() -> AppEnvironment {
        #if DEBUG
            // `-uiSampleData` launches with an in-memory database and sample entries (screenshots, UI checks).
            if ProcessInfo.processInfo.arguments.contains("-uiSampleData") {
                return AppEnvironment.preview(sampleData: true)
            }
        #endif
        return AppEnvironment.live()
    }
}
