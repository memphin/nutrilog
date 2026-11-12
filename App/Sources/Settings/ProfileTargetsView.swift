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
            // The latest weight of any source: weigh-ins entered in Vitalion and Apple Health (#65).
            let latest = try StatsLoader.dayWeights(through: today, environment: environment).last { $0.kg != nil }
            try model.load(
                profile: profiles.profile(), target: profiles.target(on: today), latestWeightKg: latest?.kg, weightDay: latest?.day,
                measured: Expenditure.measured(environment: environment),
                macrosInGrams: try? profiles.setting(TargetsModel.macrosInGramsKey, as: Bool.self),
            )
            self.model = model
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ model: TargetsModel) {
        guard let profiles = environment.profiles else { return }
        do {
            guard try model.save(to: profiles) else { return }
            savedMessage = String(localized: "New targets apply from today. Past days keep the targets they had.")
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
            Section {
                LabeledContent("Height") { trailingField($model.heightCm, "cm") }
                LabeledContent("Weight") {
                    if let weight = model.weightKg {
                        VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                            Text(DashboardFormat.kg(weight)).monospacedDigit()
                            if let day = model.weightDay {
                                Text(Format.day(day, today: model.today)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No weight yet").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Read-only. Add a weight on Today, in the Weight tile.")
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
                // With measured Health energy the activity level isn't used, so it is only asked for without it.
                if model.measured == nil {
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
            } header: {
                Text("Profile")
            } footer: {
                Text(model.weightKg == nil
                    ? "Weight comes from your weigh-ins: add one on Today → Weight, or allow Vitalion to read weight from Apple Health."
                    : "Weight is your latest weigh-in (Today → Weight, or Apple Health).")
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
                        LabeledContent(
                            "Rate",
                            value: String(localized: "\(model.rateKgPerWeek.formatted(.number.precision(.fractionLength(2)))) kg/week"),
                        )
                    }
                    LabeledContent(model.goal == .lose ? "Daily deficit" : "Daily surplus", value: unit.format(abs(model.dailyDelta)))
                }
            } header: {
                Text("Goal")
            }

            Section {
                if let measured = model.measured {
                    LabeledContent("Maintenance (measured)") {
                        VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                            Text(unit.format(measured.kcal)).monospacedDigit()
                            Text("Average total energy, \(measured.days) days").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    suggestedTarget
                } else if let bmr = model.bmr, let tdee = model.tdee {
                    LabeledContent("BMR (Mifflin-St Jeor)", value: unit.format(bmr))
                    LabeledContent("Maintenance (× \(model.activity.factor.formatted()))", value: unit.format(tdee))
                    suggestedTarget
                } else {
                    Text(model.weightKg == nil
                        ? "Add a weight on Today and fill in height, birth date and sex to calculate a target."
                        : "Fill in height, birth date and sex to calculate a target.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Set calories manually", isOn: $model.overrideKcal)
                if model.overrideKcal {
                    LabeledContent("Daily target") { trailingField($model.manualKcal, "kcal") }
                }
            } header: {
                Text("Calories")
            } footer: {
                if model.measured == nil {
                    Text("""
                    Without at least \(Energy.measuredMinimumDays) days of active and resting energy in Apple Health, maintenance \
                    is estimated from your activity level. The weekly check-in (Trends) refines this with your real intake and \
                    weight trend.
                    """)
                } else {
                    Text("""
                    Maintenance is your average total energy burned (active + resting, Apple Health) over the last \
                    \(Energy.measuredWindowDays) days. The weekly check-in (Trends) refines this with your real intake and \
                    weight trend.
                    """)
                }
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
                    LabeledContent("Total", value: "\(DisplayRounding.whole(model.percentSum)) %")
                        .foregroundStyle(abs(model.percentSum - 100) <= 0.5 ? Color.secondary : Color.red)
                    if let macros = model.macros {
                        MacroLine(protein: macros.proteinG, carbs: macros.carbsG, fat: macros.fatG)
                    }
                case .grams:
                    LabeledContent("Protein") { trailingField($model.proteinG, "g") }
                    LabeledContent("Carbs") { trailingField($model.carbsG, "g") }
                    LabeledContent("Fat") { trailingField($model.fatG, "g") }
                    if let diff = model.gramsEnergyMismatch, abs(diff) > 50 {
                        Group {
                            if diff > 0 {
                                Text("These macros add up to \(DisplayRounding.whole(abs(diff))) kcal more than the calorie target.")
                            } else {
                                Text("These macros add up to \(DisplayRounding.whole(abs(diff))) kcal less than the calorie target.")
                            }
                        }
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

    /// The suggested target, with a note when the minimum target is what sets it (so it isn't silently different
    /// from maintenance ± the goal).
    @ViewBuilder private var suggestedTarget: some View {
        if let target = model.suggestedKcal {
            LabeledContent("Suggested target", value: unit.format(target)).bold()
            if model.suggestionRaisedToFloor, let formula = model.formulaKcal {
                let minimum = unit.format(AdaptiveTDEE.minimumTargetKcal)
                Group {
                    if model.dailyDelta < 0 {
                        Text("""
                        Maintenance minus your daily deficit comes to \(unit.format(formula)), below \(minimum), the lowest \
                        target the app suggests.
                        """)
                    } else {
                        Text("Maintenance comes to \(unit.format(formula)), below \(minimum), the lowest target the app suggests.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.orange)
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
