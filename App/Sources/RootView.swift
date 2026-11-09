import SwiftUI

/// Phase 0 placeholder. Replaced by the Diary / Dashboard tab structure in Phase 1.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    switch environment.database {
                    case .ready:
                        Label("Database ready", systemImage: "checkmark.circle")
                    case let .failed(message):
                        Label("Database error: \(message)", systemImage: "exclamationmark.triangle")
                    }
                    Label(
                        environment.config.usdaAPIKey == nil ? "USDA key not set (optional)" : "USDA key configured",
                        systemImage: "key",
                    )
                }
                Section {
                    Text("Phase 0 — foundation. Food diary arrives in Phase 1.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nutrilog")
        }
    }
}

#Preview {
    RootView().environment(AppEnvironment.preview())
}
