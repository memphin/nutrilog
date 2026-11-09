import Core
import DesignSystem
import Persistence
import SwiftUI

/// Profile + calorie and macro targets (backlog #11).
struct ProfileTargetsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: TargetsModel?
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        Group {
            if let model {
                TargetsForm(model: model, unit: environment.energyUnit)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { save(model) }.disabled(!model.validationErrors.isEmpty)
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Profile & targets")
        .task { load() }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .alert("Saved", isPresented: Binding(get: { savedMessage != nil }, set: {
            if !$0 {
                savedMessage = nil
            }
        })) {
            Button("OK") { dismiss() }
        } message: { Text(savedMessage ?? "") }
    }

    private func load() {
        guard model == nil, let profiles = environment.profiles else { return }
        do {
            let today = environment.today
            let model = TargetsModel(today: today)
            try model.load(profile: profiles.profile(), target: profiles.target(on: today), latestWeightKg: profiles.latestWeight()?.kg)
            self.model = model
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ model: TargetsModel) {
        guard let profiles = environment.profiles else { return }
        do {
            guard try model.save(to: profiles) else { return }
            savedMessage = "New targets apply from today. Past days keep the targets they had."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TargetsForm: View {
    @Bindable var model: TargetsModel
    let unit: EnergyUnit

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Height") { trailingField($model.heightCm, "cm") }
                LabeledContent("Weight") { trailingField($model.weightKg, "kg") }
                Toggle("Birth date known", isOn: $model.hasBirthDate)
                if model.hasBirthDate {
                    DatePicker("Birth date", selection: $model.birthDate, in: ...Date(), displayedComponents: .date)
                }
                Picker("Sex", selection: $model.sex) {
                    Text("Not set").tag(Sex?.none)
                    Text("Male").tag(Sex?.some(.male))
                    Text("Female").tag(Sex?.some(.female))
                    Text("Other").tag(Sex?.some(.other))
                }
                Picker("Activity", selection: $model.activity) {
                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                        VStack(alignment: .leading) {
                            Text(level.title)
                            Text(level.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Picker("Goal", selection: $model.goal) {
                    Text("Lose").tag(GoalMode.lose)
                    Text("Maintain").tag(GoalMode.maintain)
                    Text("Gain").tag(GoalMode.gain)
                }
                .pickerStyle(.segmented)
                if model.goal != .maintain {
                    Stepper(value: $model.rateKgPerWeek, in: 0.1 ... 1.0, step: 0.05) {
                        LabeledContent("Rate", value: "\(model.rateKgPerWeek.formatted(.number.precision(.fractionLength(2)))) kg/week")
                    }
                    LabeledContent(model.goal == .lose ? "Daily deficit" : "Daily surplus", value: unit.format(abs(model.dailyDelta)))
                }
            } header: {
                Text("Goal")
            }

            Section {
                if let bmr = model.bmr, let tdee = model.tdee {
                    LabeledContent("BMR (Mifflin-St Jeor)", value: unit.format(bmr))
                    LabeledContent("Maintenance (× \(model.activity.factor.formatted()))", value: unit.format(tdee))
                    if let target = model.formulaKcal {
                        LabeledContent("Suggested target", value: unit.format(target)).bold()
                    }
                } else {
                    Text("Fill in height, weight, birth date and sex to calculate a target.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Set calories manually", isOn: $model.overrideKcal)
                if model.overrideKcal {
                    LabeledContent("Daily target") { trailingField($model.manualKcal, "kcal") }
                }
            } header: {
                Text("Calories")
            } footer: {
                Text("From phase 3, the weekly check-in refines this with your real intake and weight trend.")
            }

            Section {
                Picker("Enter macros as", selection: $model.macroInput) {
                    ForEach(TargetsModel.MacroInput.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.macroInput {
                case .percent:
                    LabeledContent("Protein") { trailingField($model.proteinPct, "%") }
                    LabeledContent("Carbs") { trailingField($model.carbsPct, "%") }
                    LabeledContent("Fat") { trailingField($model.fatPct, "%") }
                    LabeledContent("Total", value: "\(Int(model.percentSum.rounded())) %")
                        .foregroundStyle(abs(model.percentSum - 100) <= 0.5 ? Color.secondary : Color.red)
                    if let macros = model.macros {
                        MacroLine(protein: macros.proteinG, carbs: macros.carbsG, fat: macros.fatG)
                    }
                case .grams:
                    LabeledContent("Protein") { trailingField($model.proteinG, "g") }
                    LabeledContent("Carbs") { trailingField($model.carbsG, "g") }
                    LabeledContent("Fat") { trailingField($model.fatG, "g") }
                    if let diff = model.gramsEnergyMismatch, abs(diff) > 50 {
                        Text(
                            "These macros add up to \(diff > 0 ? "\(Int(diff)) kcal more" : "\(Int(-diff)) kcal less") than the calorie target.",
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Fiber (optional)") { trailingField($model.fiberG, "g") }
            } header: {
                Text("Macros")
            }

            if !model.validationErrors.isEmpty {
                Section {
                    ForEach(model.validationErrors, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
    }

    private func trailingField(_ text: Binding<String>, _ unitLabel: String) -> some View {
        HStack {
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unitLabel).foregroundStyle(.secondary)
        }
    }
}
