import Core
import DesignSystem
import Persistence
import SwiftUI

/// The diary's "Supplements" section: the doses due on the day with a circle to tick each one, then the extra doses,
/// and a menu to log an extra dose. Future days show the schedule without ticking.
struct DiarySupplementsSection: View {
    @Bindable var model: DiaryModel
    @State private var showManage = false
    @State private var editingTime: SupplementDay.Row?

    var body: some View {
        Section {
            if let supplementDay = model.supplementDay {
                let rows = supplementDay.rows
                ForEach(rows) { row in
                    SupplementDoseRow(
                        row: row, canLog: !model.isFuture, isOverdue: model.isOverdue(row),
                    ) { model.toggleTaken(row) }
                        .contextMenu { menu(row) }
                        .swipeActions(edge: .trailing) {
                            if row.dose != nil {
                                Button("Undo", systemImage: "arrow.uturn.backward") { model.undoLog(row) }
                            } else if !model.isFuture {
                                Button("Skip", systemImage: "forward") { model.markSkipped(row) }
                                    .tint(.gray)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if !model.isFuture, !row.isTaken {
                                Button("Taken", systemImage: "checkmark") { model.toggleTaken(row) }
                                    .tint(.green)
                            }
                        }
                }
                if supplementDay.supplements.isEmpty {
                    Button {
                        showManage = true
                    } label: {
                        Label("Add supplements or medications", systemImage: "plus")
                    }
                } else if !model.isFuture, !supplementDay.active.isEmpty {
                    Menu {
                        ForEach(supplementDay.active) { supplement in
                            Button(supplement.displayName) { model.logExtraDose(supplement) }
                        }
                    } label: {
                        Label(rows.isEmpty ? "Log a dose" : "Log an extra dose", systemImage: "plus")
                    }
                }
            }
        } header: {
            header
        }
        .sheet(isPresented: $showManage) {
            SupplementsSheet()
        }
        .sheet(item: $editingTime) { row in
            DoseTimeSheet(row: row, initial: row.dose?.takenAt ?? model.takenTime(for: row.minute)) { date in
                model.markTaken(row, at: date)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Supplements")
            Spacer()
            if let progress = model.supplementDay?.progress, progress.total > 0 {
                Text("\(progress.taken) / \(progress.total)")
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(progress.taken) of \(progress.total) taken"))
            }
            Menu {
                if !model.isFuture, model.hasOpenSupplementDoses {
                    Button("Mark all as taken", systemImage: "checkmark.circle") { model.markAllTaken() }
                }
                Button("Manage supplements…", systemImage: "pills") { showManage = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .accessibilityLabel("Supplements options")
            }
        }
    }

    @ViewBuilder
    private func menu(_ row: SupplementDay.Row) -> some View {
        if !model.isFuture {
            if !row.isTaken {
                Button("Taken", systemImage: "checkmark.circle") { model.toggleTaken(row) }
            }
            Button("Taken at…", systemImage: "clock") { editingTime = row }
            if row.key != nil, !row.isSkipped {
                Button("Skipped", systemImage: "forward") { model.markSkipped(row) }
            }
            if row.dose != nil {
                if row.key == nil {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.undoLog(row) }
                } else {
                    Button("Clear", systemImage: "arrow.uturn.backward") { model.undoLog(row) }
                }
            }
        }
    }
}

struct SupplementDoseRow: View {
    let row: SupplementDay.Row
    let canLog: Bool
    let isOverdue: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: NL.Spacing.m) {
            Button(action: toggle) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(!canLog)
            .accessibilityLabel(row.isTaken ? Text("Taken") : Text("Mark as taken"))

            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(row.supplement.name)
                    .strikethrough(row.isSkipped)
                    .foregroundStyle(row.isSkipped || !canLog ? .secondary : .primary)
                let detail = [row.supplement.dose, row.supplement.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                if let minute = row.minute {
                    Text(SupplementFormat.time(minute))
                        .monospacedDigit()
                        .foregroundStyle(isOverdue ? .orange : .secondary)
                } else {
                    Text("Extra").foregroundStyle(.secondary)
                }
                if let takenAt = row.dose?.takenAt, row.isTaken {
                    Text("taken \(takenAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if row.isSkipped {
                    Text("skipped").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if row.isTaken {
            return "checkmark.circle.fill"
        }
        return row.isSkipped ? "minus.circle" : "circle"
    }

    private var color: Color {
        if row.isTaken {
            return .green
        }
        return isOverdue ? .orange : .secondary
    }
}

/// Picks when a dose was taken.
private struct DoseTimeSheet: View {
    let row: SupplementDay.Row
    @State var time: Date
    let save: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    init(row: SupplementDay.Row, initial: Date, save: @escaping (Date) -> Void) {
        self.row = row
        _time = State(initialValue: initial)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Taken at", selection: $time, displayedComponents: .hourAndMinute)
            }
            .navigationTitle(row.supplement.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // The picked time of day on the row's day.
                        let minute = SupplementFormat.minute(of: time)
                        save(SupplementSlot(day: row.day, minute: minute).date(calendar: .autoupdatingCurrent))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
