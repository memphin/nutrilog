import DesignSystem
import SwiftUI

/// Water of another amount, or drunk earlier today: an amount in steps of 50 ml and a time between midnight and now.
struct HydrationEntrySheet: View {
    static let mlRange = 50 ... 3000
    static let mlStep = 50

    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var ml = 250
    @State private var time = Date()

    var body: some View {
        let now = model.now
        let range = model.data.today.startDate() ... max(now, time)
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $ml, in: Self.mlRange, step: Self.mlStep) {
                        LabeledContent("Amount", value: "\(ml) ml").monospacedDigit()
                    }
                    DatePicker("Time", selection: $time, in: range, displayedComponents: .hourAndMinute)
                } footer: {
                    Text("Set an earlier time for water you drank before.")
                }
            }
            .navigationTitle("Add water")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                }
            }
            .onAppear {
                time = now
                ml = model.waterSizes.first.map { min(max($0, Self.mlRange.lowerBound), Self.mlRange.upperBound) } ?? ml
            }
        }
    }

    private func add() {
        let now = model.now
        // A time picked a moment ago is "now", so the entry isn't backdated by the seconds the sheet was open.
        let at = min(time, now)
        model.addWater(ml: ml, loggedAt: now.timeIntervalSince(at) < 60 ? nil : at)
        dismiss()
    }
}
