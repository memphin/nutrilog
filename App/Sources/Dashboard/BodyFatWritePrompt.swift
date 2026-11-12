import DesignSystem
import HealthKitClient
import SwiftUI

extension SettingKey {
    /// Bool: the user dismissed the "Allow body fat writing" prompt ("Not now").
    static let bodyFatWritePromptDismissed = "bodyFatWritePromptDismissed"
}

extension AppEnvironment {
    /// True once for users who connected Health before body fat writing existed: writing is on, body mass write
    /// access was answered, body fat was never asked, and the prompt was not dismissed.
    func shouldOfferBodyFatWriting() async -> Bool {
        guard health.isAvailable, let writes = healthWrites, writes.isEnabled, writes.writer.isAvailable,
              (try? profiles?.setting(SettingKey.bodyFatWritePromptDismissed, as: Bool.self)) != true
        else { return false }
        guard await writes.writer.writeAuthorization(for: .bodyFatPercentage) == .notDetermined else { return false }
        return await writes.writer.writeAuthorization(for: .bodyMass) != .notDetermined
    }

    /// Shows the Health permission sheet (it only lists the types not answered yet), then writes what may now be
    /// written: rows that were waiting, and recent weights' body fat.
    func allowBodyFatWriting() async throws {
        try await health.requestAuthorization()
        await healthSync?.reloadAuthorization()
        await healthWrites?.writeAccessDidChange()
    }

    func dismissBodyFatWritingOffer() {
        try? profiles?.setSetting(SettingKey.bodyFatWritePromptDismissed, true)
    }
}

/// "Allow body fat writing" — a one-time offer for users who connected Health before Vitalion wrote body fat.
/// Shown in Settings → Apple Health and on the weight sheet; hidden once answered or dismissed.
struct BodyFatWritePrompt: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isOffered = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isOffered {
                Section {
                    Text("Vitalion can now also write the body fat you enter with a weight to Apple Health.")
                        .font(.subheadline)
                    Button("Allow body fat writing") { allow() }
                    Button("Not now", role: .cancel) {
                        environment.dismissBodyFatWritingOffer()
                        isOffered = false
                    }
                    .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .task { isOffered = await environment.shouldOfferBodyFatWriting() }
    }

    private func allow() {
        Task {
            do {
                try await environment.allowBodyFatWriting()
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "Couldn't ask Apple Health: \(error.localizedDescription)")
            }
            isOffered = await environment.shouldOfferBodyFatWriting()
        }
    }
}
