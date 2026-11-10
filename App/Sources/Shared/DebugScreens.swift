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
            case "smartLog":
                SmartLogView(target: AddTarget(slotID: "breakfast", day: environment.today)) {}
            case "smartLogReview":
                SmartLogView(target: AddTarget(slotID: "breakfast", day: environment.today), prefilledText: "80 g oats, 2 eggs and a banana") {}
            case "smartLogPhoto":
                // `-uiPhoto <path>`: a photo file to estimate.
                let args = ProcessInfo.processInfo.arguments
                let path = args.firstIndex(of: "-uiPhoto").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                SmartLogView(
                    target: AddTarget(slotID: "breakfast", day: environment.today),
                    prefilledPhoto: path.flatMap { FileManager.default.contents(atPath: $0) },
                ) {}
            case "diary":
                DiaryView()
            default:
                Text("Unknown screen \(name)")
            }
        }
    }
#endif
