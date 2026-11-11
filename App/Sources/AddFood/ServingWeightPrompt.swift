import Core
import DesignSystem
import FoodLookup
import Persistence
import SwiftUI

/// A saved per-serving placeholder copy waiting for its serving weight (drives the prompt sheet).
struct PendingServingWeight: Identifiable {
    let detail: FoodDetail

    var id: String {
        detail.food.id
    }
}

/// Asks for the weight of one serving when an online food only has per-serving values (backlog #22). Saving
/// converts the stored copy with ``FoodDetail/convertingPerServingPlaceholder(servingWeight:missing:)`` (shared
/// with the scan flow). "Skip" keeps the placeholder; ``QuantitySheet`` then logs it by servings only.
struct ServingWeightPrompt: View {
    let detail: FoodDetail
    let onDone: (FoodDetail) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var weightText = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var servingLabel: String {
        detail.servings.first { $0.id == detail.food.defaultServingID }?.label ?? "1 serving"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .focused($focused)
                            .accessibilityLabel("Serving weight")
                        Text(detail.food.baseUnit.symbol).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("How much does “\(servingLabel)” weigh?")
                } footer: {
                    Text(
                        "\(detail.food.name) only lists nutrition per serving. With the weight, Vitalion stores values "
                            + "per 100 \(detail.food.baseUnit.symbol) so you can log any amount. Skip to log by servings only.",
                    )
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Serving weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { onDone(detail) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(Format.number(weightText) == nil)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func save() {
        guard let grams = Format.number(weightText), let foods = environment.foods else { return }
        do {
            // Quality follows the stored copy (it may predate this search result), not the tapped draft.
            let updated = try detail.convertingPerServingPlaceholder(servingWeight: grams)
            // Also rescales what was logged, planned or saved with the placeholder, so it stays "1 serving".
            try onDone(foods.saveConvertedPlaceholder(updated))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
