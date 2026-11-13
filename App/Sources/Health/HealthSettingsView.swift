import Core
import DesignSystem
import HealthKitClient
import Observation
import Persistence
import SwiftUI

/// What Settings knows about one Health read type. Read access is opaque, so "no data" is all that can be said
/// about a type the user may have denied.
enum HealthReadStatus: Equatable {
    /// Values found in the last 90 days; `source` names where the latest one came from.
    case found(source: String?)
    /// Nothing found — not recorded, or not shared (`HealthKitClient.noDataMessage`).
    case noData
}

/// State of Settings → Apple Health: connection, last sync and data found per type.
@MainActor
@Observable
final class HealthSettingsModel {
    private(set) var isConnected = false
    private(set) var statuses: [HealthReadType: HealthReadStatus] = [:]

    func load(environment: AppEnvironment) async {
        // The shared status in `HealthSyncService`, so the dashboard follows a connect made here.
        await environment.healthSync?.reloadAuthorization()
        isConnected = environment.healthSync?.isConnected ?? false
        guard isConnected, let repository = environment.dailyMetrics, let sync = environment.healthSync else {
            statuses = [:]
            return
        }
        let rows = ((try? repository.metrics(in: sync.window)) ?? []).map(\.metrics)
        let characteristics = try? await environment.health.fetchCharacteristics()
        var result: [HealthReadType: HealthReadStatus] = [:]
        for type in HealthReadType.allCases {
            if let metric = type.metric {
                let latest = rows.last { $0.hasValue(metric) }
                result[type] = latest.map { .found(source: $0.sources[metric]) } ?? .noData
            } else {
                result[type] = characteristics?.hasValue(for: type) == true ? .found(source: nil) : .noData
            }
        }
        statuses = result
    }
}

/// Settings → Apple Health: connect (via the onboarding), sync state, and per-type data status (backlog #23).
struct HealthSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = HealthSettingsModel()
    @State private var showOnboarding = false

    var body: some View {
        Form {
            if !environment.health.isAvailable {
                Section {
                    Text("Apple Health isn't available on this device.")
                }
            } else {
                connectionSection
                BodyFatWritePrompt()
                if let writes = environment.healthWrites {
                    HealthWriteSection(writes: writes)
                }
                if model.isConnected {
                    dataSection
                }
            }
        }
        .navigationTitle("Apple Health")
        .task(id: environment.healthSync?.lastSyncedAt) { await model.load(environment: environment) }
        .sheet(isPresented: $showOnboarding, onDismiss: reload) {
            HealthOnboardingView()
        }
        .refreshable { await environment.refreshHealth() }
    }

    private var connectionSection: some View {
        Section {
            if model.isConnected {
                if case let .syncing(done, total) = environment.healthSync?.phase {
                    VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                        Text("Reading Apple Health…")
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("\(done) of \(total) days").font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    LabeledContent(
                        "Last updated",
                        value: environment.healthSync?.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened)
                            ?? String(localized: "Never"),
                    )
                }
                Button("Update now") {
                    Task { await environment.healthSync?.refresh(force: true) }
                }
                .disabled(isSyncing)
                Button("What Vitalion reads and writes") { showOnboarding = true }
            } else {
                Button("Connect Apple Health") { showOnboarding = true }
            }
            if case let .failed(message) = environment.healthSync?.phase {
                Text(message).foregroundStyle(.red)
            }
        } footer: {
            Text("To change what Vitalion may read or write, open \(HealthKitClient.permissionsPath).")
        }
    }

    private var dataSection: some View {
        Section {
            ForEach(HealthReadType.allCases) { type in
                LabeledContent(type.title) {
                    switch model.statuses[type] {
                    case let .found(source):
                        Text(source ?? String(localized: "Found", comment: "Apple Health has data of this type (no source app known)."))
                    case .noData:
                        Text(HealthKitClient.noDataMessage).multilineTextAlignment(.trailing)
                    case nil:
                        Text("—")
                    }
                }
            }
        } header: {
            Text("Last 90 days")
        } footer: {
            Text("""
            Apple Health doesn't tell apps whether you allowed reading a type, so a type without data may simply not be \
            shared with Vitalion.
            """)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = environment.healthSync?.phase {
            return true
        }
        return false
    }

    private func reload() {
        Task { await model.load(environment: environment) }
    }
}

/// Settings → Apple Health → "Write to Apple Health" (backlog #27, FR-43): the global toggle and pending writes.
struct HealthWriteSection: View {
    /// Bound straight to the service's property: no `Bool` closures or method references here (Swift 6.2 IRGen
    /// crashed on a reabstraction thunk for one).
    @Bindable var writes: HealthWriteService

    var body: some View {
        Section {
            Toggle("Write to Apple Health", isOn: $writes.writeToHealth)
            if writes.isEnabled, writes.failedCount > 0 {
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    Text("^[\(writes.failedCount) entry](inflect: true) not yet written to Apple Health")
                    if let lastError = writes.lastError {
                        Text(lastError).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Try again", action: retry)
            }
            if let error = writes.settingError {
                Text(error).foregroundStyle(.red)
            }
        } footer: {
            Text(writes.isEnabled ? Self.onFooter : Self.offFooter)
        }
    }

    static let onFooter = String(localized: """
    Nutrients of each diary entry and the water you log are written to Apple Health and kept up to date when you edit \
    or delete them.
    """)
    static let offFooter = String(localized: """
    Nothing is written to Apple Health; samples written earlier stay there, and entries you change now keep their old \
    values in Health. When you turn this back on, new changes are written again and samples of entries deleted \
    meanwhile are removed.
    """)

    private func retry() {
        Task { @MainActor in
            await writes.drain()
        }
    }
}

#if DEBUG
    #Preview {
        NavigationStack { HealthSettingsView() }.environment(AppEnvironment.preview(sampleData: true))
    }
#endif
