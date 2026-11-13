import Core
import DesignSystem
import Persistence
import SwiftUI

/// The supplements list as a sheet (from the diary).
struct SupplementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SupplementsListView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Supplements and medications: the reminders switch, the active ones in the user's order, the switched-off ones.
struct SupplementsListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var supplements: [Supplement] = []
    @State private var remindersOn = true
    @State private var permissionDenied = false
    @State private var editing: EditorTarget?
    @State private var errorMessage: String?

    struct EditorTarget: Identifiable {
        var supplement: Supplement?
        var id: String {
            supplement?.id ?? "new"
        }
    }

    private var active: [Supplement] {
        supplements.filter(\.isActive)
    }

    private var inactive: [Supplement] {
        supplements.filter { !$0.isActive }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { remindersOn }, set: { on in setReminders(on) })) {
                    Label("Reminders", systemImage: "bell")
                }
            } footer: {
                if permissionDenied {
                    Text("Notifications are off for Vitalion. Turn them on in the iOS Settings app.")
                } else {
                    Text("""
                    A notification at each dose time, and one more an hour later if a dose is still not taken. \
                    Open the app at least once a week to keep them coming.
                    """)
                }
            }

            Section {
                if active.isEmpty {
                    Text("Add the supplements and medications you take, with the times you take them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(active) { supplement in
                    row(supplement)
                }
                .onMove { from, to in
                    var ids = active.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    perform { try $0.reorder(ids + inactive.map(\.id)) }
                }
                .onDelete { offsets in
                    let ids = offsets.map { active[$0].id }
                    perform { repo in for id in ids {
                        try repo.delete(id: id)
                    } }
                }
                Button {
                    editing = EditorTarget(supplement: nil)
                } label: {
                    Label("Add supplement or medication", systemImage: "plus")
                }
            }

            if !inactive.isEmpty {
                Section("Switched off") {
                    ForEach(inactive) { supplement in
                        row(supplement)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { inactive[$0].id }
                        perform { repo in for id in ids {
                            try repo.delete(id: id)
                        } }
                    }
                }
            }
        }
        .navigationTitle("Supplements")
        .toolbar {
            if !active.isEmpty {
                EditButton()
            }
        }
        .sheet(item: $editing) { target in
            SupplementEditorView(supplement: target.supplement)
        }
        .task { await observe() }
        .task {
            remindersOn = environment.supplementRemindersEnabled
            if remindersOn {
                permissionDenied = await !(environment.supplementReminder.isAuthorized()) && hasReminded
            }
        }
        .errorAlert($errorMessage, title: "Supplements")
    }

    private var hasReminded: Bool {
        supplements.contains { $0.isActive && $0.remindersEnabled && !$0.schedule.isAsNeeded }
    }

    private func row(_ supplement: Supplement) -> some View {
        Button {
            editing = EditorTarget(supplement: supplement)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                    Text(supplement.displayName).foregroundStyle(supplement.isActive ? .primary : .secondary)
                    Text(SupplementFormat.schedule(supplement.schedule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !supplement.remindersEnabled, !supplement.schedule.isAsNeeded {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No reminders")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setReminders(_ on: Bool) {
        remindersOn = on
        Task {
            let allowed = await environment.setSupplementRemindersEnabled(on)
            permissionDenied = on && !allowed
        }
    }

    private func observe() async {
        guard let repo = environment.supplements else { return }
        await DiaryModel.resubscribing {
            repo.observeSupplements()
        } onValue: { value in
            supplements = value
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: (SupplementRepository) throws -> Void) {
        guard let repo = environment.supplements else { return }
        do {
            try action(repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
