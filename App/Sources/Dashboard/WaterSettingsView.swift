import DesignSystem
import SwiftUI

/// Settings → Water quick-add sizes (FR-46): up to four button sizes in ml.
struct WaterSettingsView: View {
    /// One size on screen. The id stays with the row while its value changes (and the rows re-sort), so a held
    /// stepper keeps acting on the same row and a deleted row is the one that animates away.
    private struct SizeRow: Identifiable, Equatable {
        let id = UUID()
        var ml: Int
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var rows: [SizeRow] = WaterQuickAdd.defaultSizes.map { SizeRow(ml: $0) }
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                    // nil disables "+" / "−" when no free step is left that way (as `in:` did at the range ends).
                    Stepper(
                        label: { LabeledContent("Button \(position + 1)", value: "\(row.ml) ml") },
                        onIncrement: canStep(row, by: 50) ? { step(row.id, by: 50) } : nil,
                        onDecrement: canStep(row, by: -50) ? { step(row.id, by: -50) } : nil,
                    )
                    .deleteDisabled(rows.count <= 1)
                }
                .onDelete { offsets in
                    // The last size can't be swiped away (`deleteDisabled`); this guard only backs that up.
                    guard rows.count > offsets.count else { return }
                    var updated = rows
                    updated.remove(atOffsets: offsets)
                    save(updated)
                }
                if rows.count < WaterQuickAdd.maximumCount {
                    Button("Add size", systemImage: "plus") {
                        if let next = WaterQuickAdd.nextSize(after: rows.map(\.ml)) {
                            save(rows + [SizeRow(ml: next)])
                        }
                    }
                    .disabled(WaterQuickAdd.nextSize(after: rows.map(\.ml)) == nil)
                }
            } footer: {
                Text("The water buttons on the Today screen, smallest first. Stepping onto another size skips past it.")
            }
            Section {
                Button("Reset to 250 and 500 ml") { save(Self.rows(for: WaterQuickAdd.defaultSizes, reusing: rows)) }
            }
        }
        .navigationTitle("Water quick-add")
        .task(id: environment.dataGeneration) {
            if let profiles = environment.profiles {
                rows = Self.rows(for: WaterQuickAdd.sizes(from: profiles), reusing: rows)
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

    private func canStep(_ row: SizeRow, by delta: Int) -> Bool {
        let others = rows.filter { $0.id != row.id }.map(\.ml)
        return WaterQuickAdd.stepped(row.ml, by: delta, among: others) != row.ml
    }

    /// A stepper tap (or autorepeat tick) on the row `id`. Looks the row up by id at call time, so a tick after the
    /// rows changed never reads a stale index; does nothing when the row is gone or no free step is left.
    private func step(_ id: SizeRow.ID, by delta: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let others = rows.filter { $0.id != id }.map(\.ml)
        let value = WaterQuickAdd.stepped(rows[index].ml, by: delta, among: others)
        guard value != rows[index].ml else { return }
        var updated = rows
        updated[index].ml = value
        save(updated)
    }

    /// Saves the sizes (sorted, unique, 1–4) and shows what was saved, keeping each row's identity.
    private func save(_ updated: [SizeRow]) {
        if let normalized = persist(updated.map(\.ml)) {
            rows = Self.rows(for: normalized, reusing: updated)
        }
    }

    /// `sizes` as rows in their order, reusing the id of an existing row with the same value where there is one.
    private static func rows(for sizes: [Int], reusing existing: [SizeRow]) -> [SizeRow] {
        var remaining = existing
        return sizes.map { ml in
            if let index = remaining.firstIndex(where: { $0.ml == ml }) {
                return remaining.remove(at: index)
            }
            return SizeRow(ml: ml)
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
