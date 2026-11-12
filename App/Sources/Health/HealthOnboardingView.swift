import DesignSystem
import HealthKitClient
import SwiftUI

/// Explains every Health type before the system permission sheet (backlog #23). Shown once on first launch and
/// from Settings → Apple Health. "Continue" shows the system sheet and closes once the user has answered; the
/// 90-day sync then runs in the background, with its progress and errors shown in Settings → Apple Health.
struct HealthOnboardingView: View {
    static let intro = String(localized: """
    Vitalion shows your Apple Health data next to what you eat. Here is what it asks for and why — Apple Health then \
    lets you allow or deny each type.
    """)
    static let privacy = String(localized: """
    Your Health data stays on this iPhone. You can change your choices at any time in \
    \(HealthKitClient.permissionsPath). Apple Health doesn't tell apps which types you didn't allow, so where data is \
    missing Vitalion shows “\(HealthKitClient.noDataMessage)”.
    """)

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.intro)
                }

                Section("Vitalion reads") {
                    ForEach(HealthReadType.allCases) { type in
                        TypeRow(title: type.title, explanation: type.explanation)
                    }
                }

                Section {
                    ForEach(HealthWriteType.allCases) { type in
                        TypeRow(title: type.title, explanation: type.explanation)
                    }
                } header: {
                    Text("Vitalion writes")
                } footer: {
                    Text("Nothing Vitalion reads from Health is ever written back.")
                }

                Section {} footer: {
                    Text(Self.privacy)
                }
            }
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .disabled(isConnecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Continue") { connect() }
                            .disabled(!environment.health.isAvailable || environment.healthSync == nil)
                    }
                }
            }
            .interactiveDismissDisabled(isConnecting)
            .alert("Apple Health", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func connect() {
        guard environment.healthSync != nil else { return }
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await environment.connectHealth()
                dismiss()
            } catch {
                errorMessage = String(localized: "Apple Health couldn't ask for access: \(error.localizedDescription)")
            }
        }
    }
}

private struct TypeRow: View {
    let title: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
            Text(title)
            Text(explanation).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HealthOnboardingView().environment(AppEnvironment.preview())
}
