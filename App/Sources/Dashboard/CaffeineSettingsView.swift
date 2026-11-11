import Core
import DesignSystem
import SwiftUI

/// Settings → Caffeine: bedtime and the sleep-safe line, what changes the half-life (or a custom one), and the
/// quick-add drinks of the Today tile.
struct CaffeineSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var settings = CaffeineSettings.default
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                DatePicker("Bedtime", selection: bedtime, displayedComponents: .hourAndMinute)
                Stepper(
                    value: binding(\.thresholdMg),
                    in: CaffeineSettings.thresholdRange,
                    step: CaffeineSettings.thresholdStep,
                ) {
                    LabeledContent("Sleep-safe below", value: CaffeineStatus.mg(settings.thresholdMg))
                }
            } header: {
                Text("Sleep")
            } footer: {
                Text(
                    "The tile says when the caffeine in your body drops below this line, and whether it will by bedtime. "
                        + "\(CaffeineStatus.mg(CaffeineDefaults.sleepSafeThresholdMg)) is a common rule of thumb.",
                )
            }

            Section {
                Toggle("Smoker", isOn: binding(\.metabolism.smoker))
                Toggle("Taking the pill", isOn: binding(\.metabolism.oralContraceptives))
                Toggle("Pregnant", isOn: binding(\.metabolism.pregnant))
                Toggle("Use custom half-life", isOn: usesCustomHalfLife)
                if let hours = settings.metabolism.overrideHours {
                    Stepper(
                        value: Binding(get: { hours }, set: { value in update { $0.metabolism.overrideHours = value } }),
                        in: CaffeineMetabolism.halfLifeRange,
                        step: CaffeineSettings.halfLifeStep,
                    ) {
                        LabeledContent("Custom half-life", value: Self.hours(hours))
                    }
                }
                LabeledContent("Caffeine half-life", value: Self.hours(settings.metabolism.halfLifeHours))
            } header: {
                Text("Metabolism")
            } footer: {
                Text(
                    "Half of the caffeine is cleared in about 5 hours for most adults. Smoking speeds this up (about 3 h); "
                        + "the pill (about 10 h) and pregnancy (up to 15 h late in pregnancy) slow it down. A custom "
                        + "half-life replaces these.",
                )
            }

            Section {
                ForEach(CaffeineDrink.all) { drink in
                    let selected = settings.quickAddIDs.contains(drink.id)
                    let full = settings.quickAddIDs.count >= CaffeineSettings.maximumQuickAdd
                    Button {
                        toggle(drink)
                    } label: {
                        HStack {
                            Label(drink.name, systemImage: drink.symbolName).foregroundStyle(.primary)
                            Spacer()
                            Text(CaffeineStatus.mg(drink.mg)).foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .opacity(selected ? 1 : 0)
                        }
                    }
                    .tint(.primary)
                    .disabled(!selected && full)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            } header: {
                Text("Quick-add drinks")
            } footer: {
                Text(
                    "Up to \(CaffeineSettings.maximumQuickAdd) buttons on the Today tile. Amounts are typical values per "
                        + "serving; real drinks vary with brew strength and brand.",
                )
            }
        }
        .navigationTitle("Caffeine")
        .task(id: environment.dataGeneration) {
            if let profiles = environment.profiles {
                settings = CaffeineSettings.load(from: profiles)
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

    /// "5 h", "7.5 h".
    static func hours(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0 ... 1)))) h"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CaffeineSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private var bedtime: Binding<Date> {
        Binding(
            get: {
                let minutes = settings.bedtimeMinutes
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                update { $0.bedtimeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            },
        )
    }

    /// On: starts from the half-life in use; off: back to the one derived from the toggles.
    private var usesCustomHalfLife: Binding<Bool> {
        Binding(
            get: { settings.metabolism.overrideHours != nil },
            set: { on in
                update { settings in
                    settings.metabolism.overrideHours = on
                        ? CaffeineSettings.normalizedHalfLife(settings.metabolism.halfLifeHours) : nil
                }
            },
        )
    }

    private func toggle(_ drink: CaffeineDrink) {
        update { settings in
            if let index = settings.quickAddIDs.firstIndex(of: drink.id) {
                // Keep at least one button.
                if settings.quickAddIDs.count > 1 {
                    settings.quickAddIDs.remove(at: index)
                }
            } else if settings.quickAddIDs.count < CaffeineSettings.maximumQuickAdd {
                // Keep the presets' order.
                let ids = Set(settings.quickAddIDs + [drink.id])
                settings.quickAddIDs = CaffeineDrink.all.map(\.id).filter(ids.contains)
            }
        }
    }

    /// Applies `change` and saves; the screen shows what was saved.
    private func update(_ change: (inout CaffeineSettings) -> Void) {
        guard let profiles = environment.profiles else { return }
        var updated = settings
        change(&updated)
        do {
            settings = try updated.save(to: profiles)
            environment.refreshHydrationReminder() // bedtime is shared with hydration
        } catch {
            errorMessage = "Couldn't save the caffeine settings: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { CaffeineSettingsView() }.environment(AppEnvironment.preview())
}
