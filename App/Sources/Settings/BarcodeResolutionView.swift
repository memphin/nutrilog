import Core
import Persistence
import SwiftUI

/// Settings → Diagnostics → Barcode resolution (backlog #30, SPEC §1.3): how well scans resolved over the last 14 days,
/// from the local scan log. Nothing here leaves the phone.
struct BarcodeResolutionView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var stats: BarcodeResolutionStats?
    @State private var confirmClear = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let stats {
                Section {
                    LabeledContent("Regularly bought products", value: Self.percent(stats.regularRate))
                    LabeledContent("All scans", value: Self.percent(stats.scanRate))
                    LabeledContent("Distinct barcodes", value: Self.percent(stats.barcodeRate))
                } header: {
                    Text("Resolved, last \(BarcodeResolutionStats.defaultDays) days")
                } footer: {
                    Text(Self.summary(stats))
                }

                Section {
                    LabeledContent("Scans before a manual entry", value: "\(stats.excusedMisses)")
                    LabeledContent("All scans, without excusing them", value: Self.percent(stats.rawScanRate))
                    LabeledContent("Regularly bought (scanned 2+ times)", value: "\(stats.regularBarcodes)")
                } header: {
                    Text("Details")
                } footer: {
                    Text("""
                    Resolved means a food on this iPhone or Open Food Facts had the barcode. A miss is not counted when \
                    a food with that barcode was added afterwards (anywhere in the app, or by an import): that's the \
                    one-time manual entry, and later scans find it on this iPhone. Offline scans aren't counted either.
                    """)
                }

                Section("By outcome") {
                    ForEach(ScanOutcome.allCases, id: \.self) { outcome in
                        LabeledContent(Self.label(outcome), value: "\(stats.count(outcome))")
                    }
                    ForEach(stats.offQualityCounts.sorted { $0.key < $1.key }, id: \.key) { quality, count in
                        LabeledContent("Open Food Facts, \(Self.qualityLabel(quality))", value: "\(count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("The scan log can't be read.")
                }
            }

            Section {
                Button("Clear log", role: .destructive) { confirmClear = true }
                    .disabled(environment.scanLog == nil)
            } footer: {
                Text("The log stays on this iPhone, isn't part of exports and is trimmed to 90 days.")
            }
        }
        .navigationTitle("Barcode resolution")
        .task { reload() }
        .refreshable { reload() }
        .confirmationDialog("Clear the scan log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) { clear() }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        stats = try? environment.scanLog?.stats()
    }

    private func clear() {
        do {
            try environment.scanLog?.clear()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Formatting

    /// One decimal, rounded toward zero, so a rate just below the target never reads as the target (26/29 is 89.6 %,
    /// not 90 %).
    static func percent(_ rate: Double?, locale: Locale = .current) -> String {
        guard let rate else { return "—" }
        return rate.formatted(.percent.precision(.fractionLength(1)).rounded(rule: .towardZero).locale(locale))
    }

    static func summary(_ stats: BarcodeResolutionStats) -> String {
        let target = BarcodeResolutionStats.target.formatted(.percent.precision(.fractionLength(0)))
        switch stats.meetsTarget {
        case true?: return String(localized: "On target: at least \(target) of regularly bought products resolve.")
        case false?: return String(localized: "Below the \(target) target for regularly bought products.")
        case nil: return String(localized: "Scan products you buy more than once to measure the \(target) target.")
        }
    }

    static func label(_ outcome: ScanOutcome) -> String {
        switch outcome {
        case .local: String(localized: "On this iPhone")
        case .offNetwork: "Open Food Facts"
        case .offCache: String(localized: "Open Food Facts (cached)")
        case .offStaleCache: String(localized: "Open Food Facts (outdated cache)")
        case .notFound: String(localized: "Not found")
        case .offline: String(localized: "Offline")
        case .unavailable: String(localized: "Open Food Facts unavailable")
        case .created: String(localized: "Created after not found")
        }
    }

    /// Lowercase: it follows "Open Food Facts, " in a row title.
    static func qualityLabel(_ raw: String) -> String {
        switch DataQuality(rawValue: raw) {
        case .complete?: String(localized: "complete", comment: "Data quality of a food's nutrition values")
        case .partialMacros?: String(localized: "partial macros")
        case .energyOnly?: String(localized: "energy only")
        case nil: raw
        }
    }
}
