import DesignSystem
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
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
