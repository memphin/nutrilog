import Core
import DesignSystem
import Persistence
import SwiftUI

/// The form behind the weight sheet (FR-42, backlog #29): kg, optional body fat, date and time.
struct WeightForm: Equatable {
    var kg = ""
    var bodyFat = ""
    var measuredAt: Date

    init(measuredAt: Date) {
        self.measuredAt = measuredAt
    }

    init(entry: WeightEntry) {
        kg = Format.field(entry.kg)
        bodyFat = Format.field(entry.bodyFatPct)
        measuredAt = entry.measuredAt
    }

    var kgValue: Double? {
        Format.number(kg).flatMap { WeightRepository.validKg.contains($0) ? $0 : nil }
    }

    enum BodyFat: Equatable {
        case empty
        case value(Double)
        case invalid
    }

    var bodyFatInput: BodyFat {
        if bodyFat.trimmingCharacters(in: .whitespaces).isEmpty {
            return .empty
        }
        guard let value = Format.number(bodyFat), WeightRepository.validBodyFatPct.contains(value) else { return .invalid }
        return .value(value)
    }

    var bodyFatValue: Double? {
        if case let .value(value) = bodyFatInput {
            return value
        }
        return nil
    }

    var isValid: Bool {
        kgValue != nil && bodyFatInput != .invalid
    }
}

struct WeightEntrySheet: View {
    let model: DashboardModel
    let editing: WeightEntry?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var form: WeightForm
    @FocusState private var focused: Bool

    init(model: DashboardModel, editing: WeightEntry?) {
        self.model = model
        self.editing = editing
        _form = State(initialValue: editing.map(WeightForm.init(entry:)) ?? WeightForm(measuredAt: Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Weight") {
                        HStack {
                            TextField("0.0", text: $form.kg)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focused)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Body fat") {
                        HStack {
                            TextField("Optional", text: $form.bodyFat)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("Measured", selection: $form.measuredAt, in: ...max(Date(), form.measuredAt))
                } footer: {
                    Text(footer)
                }
                if let editing {
                    Section {
                        Button("Delete weight", role: .destructive) {
                            model.deleteWeight(editing)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add weight" : "Edit weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!form.isValid)
                }
            }
            .onAppear { focused = editing == nil }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        environment.healthWrites?.isEnabled == false
            ? "Writing to Apple Health is off, so this weight stays in Nutrilog."
            : "Also saved to Apple Health as weight and body fat."
    }

    private func save() {
        guard let kg = form.kgValue, form.isValid else { return }
        if model.saveWeight(kg: kg, bodyFatPct: form.bodyFatValue, measuredAt: form.measuredAt, editing: editing) {
            dismiss()
        }
    }
}
