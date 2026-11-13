import DesignSystem
import Persistence
import SwiftUI

/// Settings → Backups: the automatic weekly backups kept on this iPhone — list, restore, back up now (FR-62, backlog #41).
struct BackupsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var backups: [LocalBackups.Backup] = []
    @State private var restoring: LocalBackups.Backup?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button("Back up now", systemImage: "externaldrive.badge.plus") { backUpNow() }
                    .disabled(environment.backups == nil)
            } footer: {
                Text("""
                Vitalion saves a full backup on this iPhone about once a week and keeps the newest \(LocalBackups.keep). \
                They protect against a bad import or a mistake — not against losing the phone. For that, share a \
                backup or use Export & import.
                """)
            }
            Section("Backups on this iPhone") {
                if backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: backup.url) {
                            Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        Button("Restore") { restoring = backup }
                            .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(backup) }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .task(id: environment.dataGeneration) { reload() }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { restoring != nil }, set: {
                if !$0 {
                    restoring = nil
                }
            }),
            titleVisibility: .visible,
        ) {
            Button("Replace all my data", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let date = restoring?.createdAt.formatted(date: .abbreviated, time: .shortened) {
                Text("Everything on this iPhone is replaced with the backup from \(date). A backup of the current data is made first.")
            } else {
                Text("Everything on this iPhone is replaced with the backup from then. A backup of the current data is made first.")
            }
        }
        .errorAlert($message, title: "Backups")
    }

    private func reload() {
        backups = (try? environment.backups?.list()) ?? []
    }

    private func backUpNow() {
        do {
            try environment.backups?.backupNow()
            reload()
        } catch {
            message = String(localized: "Couldn't write the backup: \(error.localizedDescription)")
        }
    }

    private func delete(_ backup: LocalBackups.Backup) {
        do {
            try environment.backups?.delete(backup)
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func restore() {
        guard let backup = restoring, let store = environment.backups else { return }
        restoring = nil
        do {
            // The data being replaced is backed up first (never pruning the chosen backup); nothing is restored when
            // that backup fails.
            let summary = try store.restoreKeepingCurrent(backup).summary
            try environment.dataDidChangeExternally()
            environment.refreshStoredWeightTrend()
            message = String(localized: "Restored \(summary.inserted) records. The data it replaced is the newest backup in the list.")
        } catch DataPortability.ImportError.newerSchema {
            message = String(localized: "This backup was made by a newer version of Vitalion. Update the app first.")
        } catch {
            message = String(localized: "Couldn't restore: \(error.localizedDescription)")
        }
        reload()
    }
}
