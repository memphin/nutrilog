import Combine
import DesignSystem
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHealthOnboarding = false

    var body: some View {
        content
            // Keep "today" current: the app may sit in the background overnight, or stay open past midnight.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    environment.refreshToday()
                    Task { await environment.healthSync?.refresh() }
                }
            }
            // Midnight, clock changes and time-zone changes move day boundaries: refresh "today" and re-sync Health.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await environment.systemTimeDidChange() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
                Task { await environment.systemTimeDidChange() }
            }
            .task {
                if isShowingTabs, await environment.shouldShowHealthOnboarding() {
                    showHealthOnboarding = true
                }
                await environment.healthSync?.refresh()
            }
            .sheet(isPresented: $showHealthOnboarding, onDismiss: environment.markHealthOnboardingShown) {
                HealthOnboardingView()
            }
    }

    /// False for the database error screen and debug screens, which should not be covered by onboarding.
    private var isShowingTabs: Bool {
        guard case .ready = environment.database else { return false }
        #if DEBUG
            return DebugScreen.requested == nil
        #else
            return true
        #endif
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
