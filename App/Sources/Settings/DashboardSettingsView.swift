import DesignSystem
import SwiftUI

/// Settings → Dashboard: which tiles Today shows, and in what order (#70; was the "Edit" sheet on Today).
struct DashboardSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var layout: DashboardLayout = .default
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(layout.visible) { tile in
                    Label(tile.title, systemImage: tile.systemImage)
                }
                .onMove { source, destination in
                    update { $0.moveVisible(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    let tiles = offsets.map { layout.visible[$0] }
                    update { layout in tiles.forEach { layout.setVisible($0, false) } }
                }
                if layout.visible.isEmpty {
                    Text("No tiles shown").foregroundStyle(.secondary)
                }
            } header: {
                Text("Shown on Today")
            } footer: {
                Text("Drag to reorder. Remove a tile to hide it.")
            }

            let hidden = layout.order.filter { !layout.isVisible($0) }
            if !hidden.isEmpty {
                Section("Hidden") {
                    ForEach(hidden) { tile in
                        Button {
                            withAnimation { update { $0.show(tile) } }
                        } label: {
                            HStack(spacing: NL.Spacing.m) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.large)
                                Label(tile.title, systemImage: tile.systemImage).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(tile.title)")
                    }
                }
            }

            Section {
                Button("Reset to default") { withAnimation { update { $0 = .default } } }
                    .disabled(layout == .default)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.dataGeneration) {
            if let profiles = environment.profiles {
                layout = DashboardLayout.load(from: profiles)
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    /// Applies `change` and saves; the layout on screen changes only when the save worked.
    private func update(_ change: (inout DashboardLayout) -> Void) {
        guard let profiles = environment.profiles else { return }
        var updated = layout
        change(&updated)
        do {
            try updated.save(to: profiles)
            layout = updated
        } catch {
            errorMessage = String(localized: "Couldn't save the dashboard layout: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationStack { DashboardSettingsView() }.environment(AppEnvironment.preview(sampleData: true))
}
