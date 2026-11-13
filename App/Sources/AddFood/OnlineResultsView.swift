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
                String(localized: "Search online"),
                systemImage: "globe",
                message: model.usdaStatus == .hidden
                    ? String(localized: "Type at least \(OnlineSearchModel.minimumQueryLength) letters to search Open Food Facts.")
                    : String(localized: """
                    Type at least \(OnlineSearchModel.minimumQueryLength) letters to search Open Food Facts and USDA \
                    FoodData Central.
                    """),
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
                EmptyStateView(
                    String(localized: "No online matches"), systemImage: "magnifyingglass",
                    message: String(localized: "Try another spelling or create the food."),
                )
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(model.results) { result in
                    Button { onSelect(result) } label: {
                        OnlineFoodRow(result: result, unit: unit, isFetching: model.fetchingResultID == result.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.fetchingResultID != nil)
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
                if model.results.contains(where: { $0.origin == .off }) {
                    Text("Contains information from Open Food Facts, contributed by Open Food Facts contributors (ODbL).")
                }
            }
        }
    }
}

/// "12 results from Open Food Facts", "USDA is rate-limited. Retrying in 42 seconds.", … for one source. A pause
/// counts down every second.
struct OnlineSourceStatusRow: View {
    let source: FoodDraft.Origin
    let status: OnlineSearchModel.SourceStatus

    var body: some View {
        HStack(spacing: NL.Spacing.s) {
            SourceBadge(source == .off ? .off : .usda)
            if case .paused = status {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(now: context.date)
                }
            } else {
                label(now: .now)
            }
            Spacer()
            if status == .loading {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(now: Date) -> some View {
        Text(Self.text(source: source, status: status, now: now))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    static func name(_ source: FoodDraft.Origin) -> String {
        source == .off ? "Open Food Facts" : "USDA"
    }

    static func text(source: FoodDraft.Origin, status: OnlineSearchModel.SourceStatus, now: Date = .now) -> String {
        let name = name(source)
        return switch status {
        case .idle, .hidden: name
        case .loading: String(localized: "Searching \(name)…")
        case let .loaded(count): String(localized: "\(count) results from \(name)")
        case .offline: String(localized: "\(name): offline")
        case let .paused(until): String(localized: "\(name) is rate-limited. Retrying \(retryText(until: until, now: now)).")
        case .busy: String(localized: "\(name) is busy. Retrying shortly.")
        case let .failed(message): message
        }
    }

    /// "in 42 seconds", "in 59 minutes"; "now" once the pause has ended.
    static func retryText(until: Date, now: Date) -> String {
        let seconds = until.timeIntervalSince(now).rounded(.up)
        guard seconds >= 1 else { return String(localized: "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(fromTimeInterval: seconds)
    }
}

/// One online hit: name, source badge, brand, and energy per 100 (or per serving when that is all the source has).
/// An Open Food Facts product shows its package size instead (nutrition is fetched when it is picked), and a spinner
/// while that fetch runs.
struct OnlineFoodRow: View {
    let result: OnlineFoodResult
    let unit: EnergyUnit
    var isFetching = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(result.name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: NL.Spacing.s) {
                    SourceBadge(result.source.badge)
                    if let brand = result.brand, !brand.isEmpty {
                        Text(brand).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let draft = result.draft, draft.dataQuality != .complete {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Some nutrients missing")
                    }
                }
            }
            Spacer()
            if isFetching {
                ProgressView().accessibilityLabel("Loading nutrition")
            } else {
                switch result.content {
                case let .food(draft):
                    VStack(alignment: .trailing, spacing: NL.Spacing.xxs) {
                        if let energy = Self.energyText(draft, unit: unit) {
                            Text(energy).monospacedDigit().foregroundStyle(.primary)
                        } else {
                            // The source has no energy value (stored as 0): "—" like the product card, never "0 kcal".
                            Text("—").foregroundStyle(.secondary).accessibilityLabel("Energy unknown")
                        }
                        Text(Self.basisLabel(draft)).font(.caption2).foregroundStyle(.secondary)
                    }
                case let .offProduct(hit):
                    if let quantity = hit.quantity {
                        Text(quantity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "539 kcal", or nil when the source has no energy value (``FoodDraft/missingNutrients``).
    static func energyText(_ draft: FoodDraft, unit: EnergyUnit) -> String? {
        draft.missingNutrients.contains(.energy) ? nil : unit.format(draft.nutrients.kcal)
    }

    private static func basisLabel(_ draft: FoodDraft) -> String {
        switch draft.basis {
        case .per100: draft.isLiquid ? String(localized: "per 100 ml") : String(localized: "per 100 g")
        case .perServing: String(localized: "per serving")
        }
    }
}
