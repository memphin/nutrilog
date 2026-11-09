import SwiftUI

@main
struct NutrilogApp: App {
    @State private var environment = NutrilogApp.makeEnvironment()

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
