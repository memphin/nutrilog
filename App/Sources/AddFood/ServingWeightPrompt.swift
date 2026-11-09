import Core
import DesignSystem
import Persistence
import SwiftUI

extension FoodDetail {
    /// Why a serving weight can't be used.
    enum ServingWeightError: LocalizedError, Equatable {
        case notPositive
        case implausible(kcalPer100: Double)

        var errorDescription: String? {
            switch self {
            case .notPositive:
                "Enter a weight above 0."
            case let .implausible(kcal):
                "That weight would mean \(Int(kcal.rounded())) kcal per 100 — more than pure fat. Check the weight."
            }
        }
    }

    /// Highest believable energy density (pure fat is ~900 kcal/100 g).
    static let maximumKcalPer100 = 900.0

    /// A per-serving placeholder copy (``isPerServingPlaceholder``) converted to real per-100 values once the user
    /// knows what one serving weighs: values are scaled by 100 ÷ `grams`, the default serving gets that weight, the
    /// per-serving flag and its note are cleared and the data quality becomes `quality`.
    func withServingWeight(_ grams: Double, quality: DataQuality) throws -> FoodDetail {
        guard grams > 0, grams.isFinite else { throw ServingWeightError.notPositive }
        let per100 = Nutrients.per100(fromServing: food.per100, servingGrams: grams)
        guard per100.kcal <= Self.maximumKcalPer100 else {
            throw ServingWeightError.implausible(kcalPer100: per100.kcal)
        }
        var detail = self
        detail.food.per100 = per100
        detail.food.perServingOnly = false
        detail.food.notes = nil
        detail.food.dataQuality = quality
        if let id = food.defaultServingID, let index = servings.firstIndex(where: { $0.id == id }) {
            detail.servings[index].grams = grams
        }
        return detail
    }
}

/// A saved per-serving placeholder copy waiting for its serving weight (drives the prompt sheet).
struct PendingServingWeight: Identifiable {
    let detail: FoodDetail
    let qualityWithWeight: DataQuality

    var id: String {
        detail.food.id
    }
}

/// Asks for the weight of one serving when an online food only has per-serving values (backlog #22). "Skip" keeps
/// the placeholder (1 serving counted as 100 g/ml), which still logs correctly by servings.
struct ServingWeightPrompt: View {
    let detail: FoodDetail
    /// Data quality once the weight is known (from the source's missing nutrients).
    let qualityWithWeight: DataQuality
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
                        "\(detail.food.name) only lists nutrition per serving. With the weight, Nutrilog stores values "
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
            let updated = try detail.withServingWeight(grams, quality: qualityWithWeight)
            try onDone(foods.save(updated))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
