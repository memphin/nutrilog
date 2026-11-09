import DesignSystem
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            // Keep "today" current: the app may sit in the background overnight, or stay open past midnight.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    environment.refreshToday()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                environment.refreshToday()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.database {
        case .ready:
            #if DEBUG
                if let screen = DebugScreen.requested {
                    DebugScreen(name: screen)
                } else {
                    tabs
                }
            #else
                tabs
            #endif
        case let .failed(message):
            ErrorStateView("The database could not be opened.\n\(message)")
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Diary", systemImage: "book.pages") {
                DiaryView()
            }
            Tab("Foods", systemImage: "fork.knife") {
                FoodsListView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}

#Preview {
    RootView().environment(AppEnvironment.preview(sampleData: true))
}
