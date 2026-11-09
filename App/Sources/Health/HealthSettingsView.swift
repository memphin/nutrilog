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
    private(set) var requestStatus: HealthAuthorizationRequestStatus = .unknown
    private(set) var statuses: [HealthReadType: HealthReadStatus] = [:]

    /// The user has answered the permission sheet (or a sync has already run), so statuses are meaningful.
    var isConnected: Bool {
        requestStatus == .unnecessary
    }

    func load(environment: AppEnvironment) async {
        requestStatus = await environment.health.authorizationRequestStatus()
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
        .refreshable { await environment.healthSync?.refresh(force: true) }
    }

    private var connectionSection: some View {
        Section {
            if model.isConnected {
                LabeledContent("Last updated") {
                    if environment.healthSync?.phase == .syncing {
                        ProgressView()
                    } else {
                        Text(environment.healthSync?.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    }
                }
                Button("Update now") {
                    Task { await environment.healthSync?.refresh(force: true) }
                }
                .disabled(environment.healthSync?.phase == .syncing)
                Button("What Nutrilog reads and writes") { showOnboarding = true }
            } else {
                Button("Connect Apple Health") { showOnboarding = true }
            }
            if case let .failed(message) = environment.healthSync?.phase {
                Text(message).foregroundStyle(.red)
            }
        } footer: {
            Text("To change what Nutrilog may read or write, open \(HealthKitClient.permissionsPath).")
        }
    }

    private var dataSection: some View {
        Section {
            ForEach(HealthReadType.allCases) { type in
                LabeledContent(type.title) {
                    switch model.statuses[type] {
                    case let .found(source):
                        Text(source ?? "Found")
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
            Text(
                "Apple Health doesn't tell apps whether you allowed reading a type, "
                    + "so a type without data may simply not be shared with Nutrilog.",
            )
        }
    }

    private func reload() {
        Task { await model.load(environment: environment) }
    }
}

#Preview {
    NavigationStack { HealthSettingsView() }.environment(AppEnvironment.preview(sampleData: true))
}
