import DesignSystem
import SwiftUI

/// Settings → Water quick-add sizes (FR-46): up to four button sizes in ml.
struct WaterSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var sizes: [Int] = WaterQuickAdd.defaultSizes
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(sizes.indices, id: \.self) { index in
                    Stepper(value: Binding(get: { sizes[index] }, set: { update(index, to: $0) }), in: WaterQuickAdd.validRange, step: 50) {
                        LabeledContent("Button \(index + 1)", value: "\(sizes[index]) ml")
                    }
                }
                .onDelete { offsets in
                    guard sizes.count > 1 else { return }
                    var updated = sizes
                    updated.remove(atOffsets: offsets)
                    save(updated)
                }
                if sizes.count < WaterQuickAdd.maximumCount {
                    Button("Add size", systemImage: "plus") {
                        if let next = WaterQuickAdd.nextSize(after: sizes) {
                            save(sizes + [next])
                        }
                    }
                    .disabled(WaterQuickAdd.nextSize(after: sizes) == nil)
                }
            } footer: {
                Text("The water buttons on the Today screen. Duplicate sizes are merged.")
            }
            Section {
                Button("Reset to 250 and 500 ml") { save(WaterQuickAdd.defaultSizes) }
            }
        }
        .navigationTitle("Water quick-add")
        .task(id: environment.dataGeneration) {
            if let profiles = environment.profiles {
                sizes = WaterQuickAdd.sizes(from: profiles)
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

    private func update(_ index: Int, to value: Int) {
        var updated = sizes
        updated[index] = value
        // Show what was saved: sorted, duplicates merged (stepping onto another size merges the two).
        save(updated)
    }

    private func save(_ updated: [Int]) {
        if let normalized = persist(updated) {
            sizes = normalized
        }
    }

    @discardableResult
    private func persist(_ updated: [Int]) -> [Int]? {
        guard let profiles = environment.profiles else { return nil }
        do {
            return try WaterQuickAdd.save(updated, to: profiles)
        } catch {
            errorMessage = "Couldn't save the sizes: \(error.localizedDescription)"
            return nil
        }
    }
}
