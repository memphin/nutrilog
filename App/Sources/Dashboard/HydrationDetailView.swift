import Core
import DesignSystem
import Persistence
import SwiftUI

/// The Hydration tile's detail (spec §3): the total and where the day stands; the running total against the pace
/// line with the gaps; water, other drinks and other apps' water; adding water, also at an earlier time; today's
/// drinks (water and caffeine quick-adds deletable with undo, diary drinks read-only with their meal); the last 14
/// days against each day's goal; how it works.
struct HydrationDetailView: View {
    @Bindable var model: DashboardModel
    @State private var history: [TileHistoryRow] = []
    @State private var mealNames: [String: String] = [:]
    @State private var showsEntrySheet = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content(model.hydrationDay(at: model.now))
        }
        .navigationTitle("Hydration")
        // Popping back from "Hydration settings" doesn't fire the dashboard root's onAppear; re-read them here.
        .onAppear { model.reloadSettings() }
        .refreshable { await model.refresh() }
        .task(id: model.data) {
            history = model.history(for: .water)
            mealNames = model.diaryMealNames(for: model.data.hydrationIntakes[model.data.today] ?? [])
        }
        .sheet(isPresented: $showsEntrySheet) { HydrationEntrySheet(model: model) }
        .undoToast(model.undo)
    }

    private func content(_ day: HydrationDay) -> some View {
        List {
            header(day)
            breakdown(day)

            Section {
                Menu {
                    ForEach(model.waterSizes, id: \.self) { size in
                        Button("\(size) ml", systemImage: "drop.fill") { model.addWater(ml: size) }
                    }
                    Divider()
                    Button("Other amount or time…", systemImage: "clock") { showsEntrySheet = true }
                } label: {
                    Label("Add water", systemImage: "plus")
                }
            }

            todaysDrinks(day)

            Section {
                ForEach(history) { row in
                    historyRow(row)
                }
            } header: {
                Text("Last \(TileHistory.days) days")
            }

            Section {
                NavigationLink("Hydration settings") { HydrationSettingsView() }
            }

            Section("How this works") {
                Text(Self.explanation(gapThreshold: model.data.hydrationSettings.gapThreshold))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ day: HydrationDay) -> some View {
        Section {
            VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.xs) {
                    Text(HydrationTileText.amount(day))
                        .font(NL.Typography.largeNumber).monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(GoalColor.hydration(day.status))
                    Text(HydrationTileText.goal(day)).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(HydrationStatusText.line(day.status, now: day.now)).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HydrationChart(day: day)
                .frame(height: 220)
                .listRowInsets(EdgeInsets(top: NL.Spacing.m, leading: NL.Spacing.l, bottom: NL.Spacing.m, trailing: NL.Spacing.l))
        }
    }

    private func breakdown(_ day: HydrationDay) -> some View {
        Section {
            LabeledContent("Water", value: DashboardFormat.ml(day.waterMl))
            LabeledContent("Other drinks", value: DashboardFormat.ml(day.otherDrinksMl))
            LabeledContent("Water from other apps", value: DashboardFormat.ml(day.otherAppsMl))
        } header: {
            Text("Breakdown")
        } footer: {
            Text("Water from other apps comes from Apple Health without times, so it isn't on the chart.")
        }
        .monospacedDigit()
    }

    @ViewBuilder private func todaysDrinks(_ day: HydrationDay) -> some View {
        let intakes = day.intakes.reversed()
        if !intakes.isEmpty {
            Section {
                ForEach(Array(intakes)) { intake in
                    LabeledContent {
                        Text(DashboardFormat.ml(intake.ml)).monospacedDigit()
                    } label: {
                        Text(intake.name)
                        Text([intake.at.formatted(date: .omitted, time: .shortened), mealNames[intake.id]]
                            .compactMap(\.self).joined(separator: " · "))
                    }
                    .swipeActions {
                        if intake.isDeletable {
                            Button("Delete", role: .destructive) { model.deleteIntake(intake) }
                        }
                    }
                }
            } header: {
                Text("Today's drinks")
            } footer: {
                Text("Drinks from the diary are changed or deleted in the diary.")
            }
        }
    }

    private func historyRow(_ row: TileHistoryRow) -> some View {
        let style = if let amount = row.amountMl, let goal = row.goalMl {
            AnyShapeStyle(GoalColor.water(amount, goalMl: goal))
        } else {
            AnyShapeStyle(.tertiary)
        }
        return LabeledContent(Format.day(row.day, today: model.data.today)) {
            HStack(spacing: NL.Spacing.xs) {
                Text(row.value ?? "—").foregroundStyle(style)
                if let detail = row.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
        .accessibilityValue([row.value ?? "none", row.detail].compactMap(\.self).joined(separator: " "))
    }

    /// "How this works": what counts, the pace line, the gaps.
    static func explanation(gapThreshold: TimeInterval) -> String {
        "Every drink counts: water, drinks in your diary and caffeine drinks. Oils, and foods you switch off as a "
            + "drink, don't. The pace line runs from when you woke up (from Apple Health sleep, or your wake-up time) "
            + "to an hour before bedtime. A gap is a stretch of more than \(HydrationStrip.gapDuration(gapThreshold)) "
            + "without a drink, as set in Hydration settings."
    }
}

/// The detail's status line: "Goal reached", "On pace", "500 ml behind pace", "No drink for 3 h 20 min".
enum HydrationStatusText {
    static func line(_ status: HydrationStatus, now: Date) -> String {
        switch status {
        case .goalReached: "Goal reached"
        case .onPace: "On pace"
        case let .behind(byMl): "\(DashboardFormat.ml(byMl)) behind pace"
        case let .inGap(since): "No drink for \(HydrationStrip.gapDuration(now.timeIntervalSince(since)))"
        }
    }
}

extension FluidIntake {
    /// Water and caffeine quick-adds can be deleted from the Hydration detail; diary drinks only in the diary.
    var isDeletable: Bool {
        source != .diary
    }
}
