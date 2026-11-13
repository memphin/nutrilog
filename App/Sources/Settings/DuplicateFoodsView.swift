import DesignSystem
import Persistence
import SwiftUI

/// Settings → Duplicate foods: foods that share a barcode or the same name and brand, merged into one (FR-26, #41).
struct DuplicateFoodsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var groups: [[FoodDetail]] = []
    /// The food to keep per group; default: the suggested keeper (the group's first food).
    @State private var keep: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        List {
            if groups.isEmpty {
                EmptyStateView(
                    String(localized: "No duplicates found"), systemImage: "checkmark.circle",
                    message: String(localized: "Foods with the same barcode, or the same name and brand, would show up here."),
                )
                .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.first?.id) { group in
                Section {
                    ForEach(group) { detail in
                        let isKept = keeper(of: group) == detail.food.id
                        Button { keep[groupID(group)] = detail.food.id } label: {
                            HStack {
                                Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isKept ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                                    FoodRow(detail.food, unit: environment.energyUnit)
                                    Text(Self.facts(detail)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isKept ? .isSelected : [])
                    }
                    Button("Merge into the selected food") { merge(group) }
                } footer: {
                    Text("Diary entries and saved meals of the others move to the selected food. Logged values don't change.")
                }
            }
        }
        .navigationTitle("Duplicate foods")
        .task(id: environment.dataGeneration) { reload() }
        .errorAlert($message, title: "Duplicate foods")
    }

    /// "Logged 12 times · 1 barcode · 2 servings".
    static func facts(_ detail: FoodDetail) -> String {
        var parts = [String(localized: "Logged \(detail.food.useCount) times")]
        if !detail.barcodes.isEmpty {
            parts.append(String(localized: "\(detail.barcodes.count) barcodes"))
        }
        if !detail.servings.isEmpty {
            parts.append(String(localized: "\(detail.servings.count) servings"))
        }
        if detail.food.dataQuality != .complete {
            parts.append(String(localized: "incomplete nutrition"))
        }
        return parts.joined(separator: " · ")
    }

    private func groupID(_ group: [FoodDetail]) -> String {
        group.map(\.food.id).sorted().joined(separator: ",")
    }

    private func keeper(of group: [FoodDetail]) -> String? {
        keep[groupID(group)] ?? group.first?.food.id
    }

    private func reload() {
        do {
            groups = try environment.foods?.duplicateGroups() ?? []
        } catch {
            message = error.localizedDescription
        }
    }

    private func merge(_ group: [FoodDetail]) {
        guard let keepID = keeper(of: group), let foods = environment.foods else { return }
        do {
            try foods.merge(keep: keepID, remove: group.map(\.food.id).filter { $0 != keepID })
        } catch {
            message = String(localized: "Couldn't merge: \(error.localizedDescription)")
        }
        reload()
    }
}
