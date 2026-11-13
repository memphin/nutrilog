import Core
import DesignSystem
import Persistence
import SwiftUI

/// One month of the history calendar.
struct HistoryMonth: Identifiable, Equatable {
    struct Day: Identifiable, Equatable {
        var day: LocalDay
        var adherence: Adherence
        var kcal: Double?
        var isFuture: Bool
        var isTraining = false

        var id: LocalDay {
            day
        }
    }

    var start: LocalDay
    /// Empty cells before the 1st so it lands under its weekday.
    var leadingBlanks: Int
    var days: [Day]

    var id: LocalDay {
        start
    }
}

/// Builds the months of the history calendar (FR-50, backlog #37). Pure.
enum HistoryCalendar {
    static let months = 24

    /// `months` months ending with the month of `today`, oldest first. Each day gets the adherence band of its
    /// energy against the target in effect on that day, boosted on a training day (`training` must cover the days
    /// shown, `days(today:months:)`).
    static func build(
        today: LocalDay,
        summaries: [DiaryDaySummary],
        targets: EffectiveTimeline<Target>,
        training: TrainingDays = .none,
        firstWeekday: Int,
        months: Int = months,
    ) -> [HistoryMonth] {
        let byDay = Dictionary(summaries.map { ($0.day, $0) }) { first, _ in first }
        return (0 ..< months).reversed().map { offset in
            let start = today.addingMonths(-offset)
            let days = (0 ..< start.daysInMonth).map { index -> HistoryMonth.Day in
                let day = start.adding(days: index)
                let summary = byDay[day]
                let kcal = summary.flatMap { $0.entryCount > 0 || $0.isComplete ? $0.totals.kcal : nil }
                // Today is judged once it is over (or marked as fully logged): a morning's breakfast is not "off target".
                let isOpen = day == today && summary?.isComplete != true
                let targetKcal = training.effectiveTarget(targets.value(on: day), on: day)?.kcal
                return HistoryMonth.Day(
                    day: day,
                    adherence: isOpen ? .notLogged : Adherence.band(kcal: kcal, targetKcal: targetKcal),
                    kcal: kcal, isFuture: day > today, isTraining: training.isTraining(day),
                )
            }
            return HistoryMonth(start: start, leadingBlanks: (start.weekday - firstWeekday + 7) % 7, days: days)
        }
    }

    /// The first day shown.
    static func firstDay(today: LocalDay, months: Int = months) -> LocalDay {
        today.addingMonths(-(months - 1))
    }

    /// Every day shown: from `firstDay` to the end of today's month.
    static func days(today: LocalDay, months: Int = months) -> ClosedRange<LocalDay> {
        firstDay(today: today, months: months) ... today.addingMonths(1).previous
    }
}

extension Adherence {
    var color: Color {
        switch self {
        case .onTarget: .green
        case .near: .yellow
        case .off: .red
        case .noTarget: .blue.opacity(0.5)
        case .notLogged: Color(.systemGray5)
        }
    }
}

/// Month grid of the last two years; each day is colored by how close its calories were to that day's target.
/// Tapping a day opens it in the diary.
struct HistoryCalendarView: View {
    /// A tap on a day: shows it in the diary.
    let onOpenDay: (LocalDay) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var months: [HistoryMonth] = []
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NL.Spacing.xl) {
                ForEach(months) { month in
                    monthView(month)
                }
                legend
            }
            .padding(.horizontal, NL.Spacing.l)
            .padding(.bottom, NL.Spacing.xl)
        }
        .defaultScrollAnchor(.bottom) // open on the current month; older months are above
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        // Rebuilt when the day changes too, so a calendar left open overnight moves "today" along; and whenever the
        // training days change (a day's switch here or in the diary, Settings).
        .task(id: CalendarKey(today: environment.today, generation: environment.dataGeneration)) { await observe() }
        .errorAlert($errorMessage, title: "History")
    }

    private struct CalendarKey: Hashable {
        var today: LocalDay
        var generation: Int
    }

    private func monthView(_ month: HistoryMonth) -> some View {
        VStack(alignment: .leading, spacing: NL.Spacing.s) {
            Text(month.start.startDate().formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0 ..< month.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 40)
                }
                ForEach(month.days) { day in
                    DayCell(
                        day: day, isToday: day.day == environment.today, unit: environment.energyUnit,
                        open: { onOpenDay(day.day) },
                        toggleTraining: { toggleTraining(day.day) },
                    )
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xs) {
            ForEach([Adherence.onTarget, .near, .off, .noTarget, .notLogged], id: \.self) { band in
                HStack(spacing: NL.Spacing.s) {
                    RoundedRectangle(cornerRadius: 4).fill(band.color).frame(width: 16, height: 16)
                    Text(band.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: NL.Spacing.s) {
                Image(systemName: TrainingDayFormat.symbol(isTraining: true))
                    .font(.caption2)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Training day").font(.caption)
            }
            .foregroundStyle(.secondary)
            Text("Each day is compared with the calorie target that applied on that day.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Builds the months now and again after every change to the training days.
    private func observe() async {
        let today = environment.today
        guard let repo = environment.trainingDays else {
            load(training: .none)
            return
        }
        await DiaryModel.resubscribing {
            repo.observeTrainingDays(in: HistoryCalendar.days(today: today))
        } onValue: { training in
            load(training: training)
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    private func load(training: TrainingDays) {
        guard let diary = environment.diary, let profiles = environment.profiles else { return }
        do {
            let today = environment.today
            months = try HistoryCalendar.build(
                today: today,
                summaries: diary.daySummaries(in: HistoryCalendar.firstDay(today: today) ... today),
                targets: profiles.targetTimeline(),
                training: training,
                firstWeekday: Calendar.current.firstWeekday,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A day's "Training day" / "Not a training day": the observation rebuilds the months.
    private func toggleTraining(_ day: LocalDay) {
        if let message = environment.toggleTrainingDay(day) {
            errorMessage = message
        }
    }
}

private struct DayCell: View {
    let day: HistoryMonth.Day
    let isToday: Bool
    let unit: EnergyUnit
    let open: () -> Void
    let toggleTraining: () -> Void

    var body: some View {
        Button(action: open) {
            Text("\(day.day.day)")
                .font(.callout.monospacedDigit())
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(day.isFuture ? .tertiary : .primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    day.isFuture ? Color.clear : day.adherence.color.opacity(day.adherence == .notLogged ? 1 : 0.55),
                    in: RoundedRectangle(cornerRadius: NL.Radius.s),
                )
                .overlay(alignment: .topTrailing) {
                    if day.isTraining {
                        Image(systemName: TrainingDayFormat.symbol(isTraining: true))
                            .font(.caption2)
                            .imageScale(.small)
                            .foregroundStyle(day.isFuture ? .tertiary : .secondary)
                            .padding(NL.Spacing.xxs)
                    }
                }
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: NL.Radius.s).strokeBorder(Color.primary, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(day.isFuture)
        .contextMenu {
            if !day.isFuture {
                trainingButton
            }
        }
        .accessibilityLabel(label)
        .accessibilityHint("Opens the day in the diary")
        .accessibilityActions {
            if !day.isFuture {
                trainingButton
            }
        }
    }

    /// Switches the day: "Not a training day" on a training day, "Training day" on a rest day.
    @ViewBuilder private var trainingButton: some View {
        if day.isTraining {
            Button("Not a training day", systemImage: TrainingDayFormat.symbol(isTraining: false), action: toggleTraining)
        } else {
            Button("Training day", systemImage: TrainingDayFormat.symbol(isTraining: true), action: toggleTraining)
        }
    }

    private var label: String {
        let date = day.day.startDate().formatted(.dateTime.weekday(.wide).day().month(.wide))
        let training = day.isTraining ? ", \(String(localized: "Training day"))" : ""
        guard let kcal = day.kcal else { return "\(date), \(day.adherence.title)\(training)" }
        let state = isToday && day.adherence == .notLogged ? String(localized: "in progress") : day.adherence.title
        return "\(date), \(unit.format(kcal)), \(state)\(training)"
    }
}
