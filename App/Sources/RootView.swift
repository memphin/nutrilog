import Combine
import DesignSystem
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHealthOnboarding = false
    @State private var showCheckIn = false

    var body: some View {
        content
            // Keep "today" current: the app may sit in the background overnight, or stay open past midnight.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    environment.refreshToday()
                    Task {
                        await environment.healthSync?.refresh()
                        await environment.healthSync?.waitForSync()
                        environment.refreshStoredWeightTrend()
                        environment.refreshHydrationReminder() // drinks may have been logged in other apps
                    }
                    Task { await environment.healthDidEnterForeground() }
                    environment.backupIfDue()
                    offerCheckInIfDue()
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
                await environment.healthSync?.waitForSync()
                environment.refreshStoredWeightTrend()
                environment.backupIfDue()
                offerCheckInIfDue()
            }
            // The widgets read a snapshot of today that follows every change while the app runs (backlog #42).
            .task(id: environment.today) { await WidgetSnapshotWriter.keepCurrent(environment: environment) }
            .sheet(isPresented: $showHealthOnboarding, onDismiss: environment.markHealthOnboardingShown) {
                HealthOnboardingView()
            }
            .sheet(isPresented: $showCheckIn) {
                CheckInView()
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

    /// On the check-in weekday, opens the check-in sheet by itself — once that day, only when there is an estimate
    /// to show and no check-in was made yet (SPEC §5.4.1 step 6). Any other time it is in Trends.
    private func offerCheckInIfDue() {
        guard isShowingTabs, !showHealthOnboarding, !showCheckIn, let profiles = environment.profiles,
              let snapshot = try? Expenditure.snapshot(environment: environment),
              CheckInPrompt.shouldOpen(
                  snapshot: snapshot, promptedDay: try? profiles.setting(SettingKey.checkInPromptedDay, as: String.self),
              )
        else { return }
        try? profiles.setSetting(SettingKey.checkInPromptedDay, snapshot.today.isoString)
        showCheckIn = true
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
            ErrorStateView(String(localized: "The database could not be opened.\n\(message)"))
        }
    }

    private var tabs: some View {
        @Bindable var environment = environment
        return TabView(selection: $environment.selectedTab) {
            Tab("Today", systemImage: "square.grid.2x2", value: AppTab.today) {
                DashboardView()
            }
            Tab("Diary", systemImage: "book.pages", value: AppTab.diary) {
                DiaryView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: AppTab.trends) {
                TrendsView()
            }
            Tab("Foods", systemImage: "fork.knife", value: AppTab.foods) {
                FoodsListView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
    }
}

/// When the check-in sheet opens by itself.
enum CheckInPrompt {
    /// True on the check-in weekday when an estimate exists, no check-in covers this week yet and the sheet has not
    /// already opened by itself today.
    static func shouldOpen(snapshot: ExpenditureSnapshot, promptedDay: String?) -> Bool {
        snapshot.today.weekday == snapshot.profile.checkinWeekday && snapshot.kcal != nil && snapshot.isCheckInDue
            && promptedDay != snapshot.today.isoString
    }
}

#Preview {
    RootView().environment(AppEnvironment.preview(sampleData: true))
}
