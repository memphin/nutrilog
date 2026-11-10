#if DEBUG
    import SwiftUI

    /// `-uiScreen <name>` opens one screen directly (UI checks and screenshots). Debug builds only.
    struct DebugScreen: View {
        let name: String
        @Environment(AppEnvironment.self) private var environment

        static var requested: String? {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-uiScreen"), index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        var body: some View {
            switch name {
            case "dashboard":
                DashboardView()
            case "addFood":
                AddFoodView(target: AddTarget(slotID: "breakfast", day: environment.today))
            case "scan":
                ScanView(target: AddTarget(slotID: "breakfast", day: environment.today)) {}
            case "foodEditor":
                FoodEditorView(initialName: "Ajvar")
            case "quickAdd":
                QuickAddView(mode: .create(slotID: "snacks", day: environment.today))
            case "targets":
                NavigationStack { ProfileTargetsView() }
            case "settings":
                SettingsView()
            case "foods":
                FoodsListView()
            case "health":
                NavigationStack { HealthSettingsView() }
            case "healthOnboarding":
                HealthOnboardingView()
            case "quantity":
                NavigationStack {
                    if let food = try? environment.foods?.recents(slotID: "breakfast").first,
                       let detail = try? environment.foods?.detail(id: food.id)
                    {
                        QuantitySheet(detail: detail, mode: .log(slotID: "breakfast", day: environment.today)) {}
                    }
                }
            case "trends":
                TrendsView()
            case "checkIn":
                CheckInView()
            case "checkInHistory":
                NavigationStack { CheckInHistoryView() }
            case "history":
                NavigationStack { HistoryCalendarView() }
            case "weeklyReport":
                NavigationStack { WeeklyReportView() }
            case "chartWeight":
                NavigationStack { MetricChartScreen(metric: .weight) }
            case "chartEnergy":
                NavigationStack { MetricChartScreen(metric: .energy) }
            case "chartMacros":
                NavigationStack { MetricChartScreen(metric: .macros) }
            case "chartSteps":
                NavigationStack { MetricChartScreen(metric: .steps) }
            case "meal":
                MealEditorView(mealID: (try? environment.meals?.templates())?.first?.id)
            case "duplicates":
                NavigationStack { DuplicateFoodsView() }
            case "backups":
                NavigationStack { BackupsView() }
            case "diary":
                DiaryView()
            default:
                Text("Unknown screen \(name)")
            }
        }
    }
#endif
