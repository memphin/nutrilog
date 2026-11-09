import Core
import DesignSystem
import FoodSources
import Persistence
import SwiftUI

/// List rows of the "Online" segment: one status line per source, then the merged results with OFF/USDA badges
/// (backlog #22, FR-20). Owns no state; ``OnlineSearchModel`` does.
struct OnlineResultsView: View {
    let model: OnlineSearchModel
    /// The search field's text (the model's ``OnlineSearchModel/query`` lags behind by the debounce).
    let text: String
    let unit: EnergyUnit
    let onSelect: (OnlineFoodResult) -> Void

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < OnlineSearchModel.minimumQueryLength {
            EmptyStateView(
                "Search online",
                systemImage: "globe",
                message: "Type at least \(OnlineSearchModel.minimumQueryLength) letters to search Open Food Facts"
                    + (model.usdaStatus == .hidden ? "." : " and USDA FoodData Central."),
            )
            .listRowBackground(Color.clear)
        } else {
            Section {
                if model.offStatus == .offline, model.usdaStatus == .offline || model.usdaStatus == .hidden {
                    Label("You're offline. Online search needs a connection.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                } else {
                    OnlineSourceStatusRow(source: .off, status: model.offStatus)
                    if model.usdaStatus != .hidden {
                        OnlineSourceStatusRow(source: .usda, status: model.usdaStatus)
                    }
                }
            }
            if model.showsNoMatches {
                EmptyStateView("No online matches", systemImage: "magnifyingglass", message: "Try another spelling or create the food.")
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(model.results) { result in
                    Button { onSelect(result) } label: {
                        OnlineFoodRow(result: result, unit: unit)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let url = result.offProductURL {
                            Link(destination: url) { Label("View on Open Food Facts", systemImage: "safari") }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if let url = result.offProductURL {
                            Link(destination: url) { Label("Open Food Facts", systemImage: "safari") }
                                .tint(.orange)
                        }
                    }
                }
            } footer: {
                if model.results.contains(where: { $0.draft.origin == .off }) {
                    Text("Contains information from Open Food Facts, contributed by Open Food Facts contributors (ODbL).")
                }
            }
        }
    }
}

/// "Open Food Facts · 12 results", "USDA paused until 14:05", … for one source.
struct OnlineSourceStatusRow: View {
    let source: FoodDraft.Origin
    let status: OnlineSearchModel.SourceStatus

    var body: some View {
        HStack(spacing: NL.Spacing.s) {
            SourceBadge(source == .off ? .off : .usda)
            Text(Self.text(source: source, status: status))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if status == .loading {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func name(_ source: FoodDraft.Origin) -> String {
        source == .off ? "Open Food Facts" : "USDA"
    }

    static func text(source: FoodDraft.Origin, status: OnlineSearchModel.SourceStatus) -> String {
        let name = name(source)
        return switch status {
        case .idle, .hidden: name
        case .loading: "Searching \(name)…"
        case let .loaded(count): count == 1 ? "1 result from \(name)" : "\(count) results from \(name)"
        case .offline: "\(name): offline"
        case let .paused(until): "\(name) paused until \(until.formatted(date: .omitted, time: .shortened)) (rate limit)"
        case .busy: "\(name) is busy. Try again in a minute."
        case let .failed(message): message
        }
    }
}

/// One online hit: name, source badge, brand, energy per 100 (or per serving when that is all the source has).
struct OnlineFoodRow: View {
    let result: OnlineFoodResult
    let unit: EnergyUnit

    var body: some View {
        let draft = result.draft
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(result.name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: NL.Spacing.s) {
                    SourceBadge(result.source.badge)
                    if let brand = result.brand, !brand.isEmpty {
                        Text(brand).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if draft.dataQuality != .complete {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Some nutrients missing")
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                Text(unit.format(draft.nutrients.kcal)).monospacedDigit().foregroundStyle(.primary)
                Text(basisLabel).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var basisLabel: String {
        switch result.draft.basis {
        case .per100: result.draft.isLiquid ? "per 100 ml" : "per 100 g"
        case .perServing: "per serving"
        }
    }
}
