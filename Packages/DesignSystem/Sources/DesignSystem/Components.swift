import SwiftUI

// MARK: - Energy ring

/// Calories remaining ring for the day summary (FR-6).
public struct EnergyRing: View {
    let consumed: Double
    let target: Double?
    let unit: String
    let lineWidth: CGFloat

    /// - Parameters:
    ///   - consumed/target: in the display unit (kcal or kJ).
    public init(consumed: Double, target: Double?, unit: String = "kcal", lineWidth: CGFloat = 12) {
        self.consumed = consumed
        self.target = target
        self.unit = unit
        self.lineWidth = lineWidth
    }

    public var body: some View {
        let progress = Progress(value: consumed, target: target)
        ZStack {
            Circle().stroke(NL.Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress.fraction)
                .stroke(progress.isOver ? NL.Palette.over : NL.Palette.energy, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: progress.fraction)
            VStack(spacing: NL.Spacing.xxs) {
                if let target {
                    let remaining = target - consumed
                    Text(abs(remaining).formatted(.number.precision(.fractionLength(0))))
                        .font(NL.Typography.number)
                        .foregroundStyle(remaining < 0 ? NL.Palette.over : .primary)
                        .contentTransition(.numericText())
                    Text(
                        remaining < 0
                            ? String(localized: "\(unit) over", bundle: .module, comment: "Energy ring caption, e.g. “kcal over”")
                            : String(localized: "\(unit) left", bundle: .module, comment: "Energy ring caption, e.g. “kcal left”"),
                    )
                    .font(NL.Typography.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(consumed.formatted(.number.precision(.fractionLength(0))))
                        .font(NL.Typography.number)
                    Text(String(localized: "\(unit) eaten", bundle: .module, comment: "Energy ring caption, e.g. “kcal eaten”"))
                        .font(NL.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(lineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.energyRemaining(consumed: consumed, target: target, unit: unit))
    }
}

// MARK: - Macro bar

/// Horizontal progress bar for one nutrient against its target.
public struct MacroBar: View {
    let title: String
    let value: Double
    let target: Double?
    let unit: String
    let color: Color

    public init(title: String, value: Double, target: Double?, unit: String = "g", color: Color) {
        self.title = title
        self.value = value
        self.target = target
        self.unit = unit
        self.color = color
    }

    public init(macro: Macro, value: Double, target: Double?) {
        self.init(title: macro.title, value: value, target: target, color: macro.color)
    }

    public var body: some View {
        let progress = Progress(value: value, target: target)
        VStack(alignment: .leading, spacing: NL.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(NL.Typography.label)
                Spacer(minLength: NL.Spacing.xs)
                Group {
                    if let target {
                        Text(verbatim: "\(Self.text(value)) / \(Self.text(target)) \(unit)")
                    } else {
                        Text(verbatim: "\(Self.text(value)) \(unit)")
                    }
                }
                .font(NL.Typography.smallNumber)
                .foregroundStyle(progress.isOver ? NL.Palette.over : .secondary)
                .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NL.Palette.track)
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * progress.fraction))
                        .animation(.snappy, value: progress.fraction)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.progress(label: title, value: value, target: target, unit: unit))
    }

    nonisolated static func text(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
}

// MARK: - Nutrient row

/// "Protein ........ 12.5 g" row for nutrient tables.
public struct NutrientRow: View {
    let title: String
    let value: Double?
    let unit: String
    let indent: Bool
    let emphasized: Bool

    public init(_ title: String, value: Double?, unit: String = "g", indent: Bool = false, emphasized: Bool = false) {
        self.title = title
        self.value = value
        self.unit = unit
        self.indent = indent
        self.emphasized = emphasized
    }

    public var body: some View {
        HStack {
            Text(title)
                .padding(.leading, indent ? NL.Spacing.l : 0)
                .foregroundStyle(indent ? .secondary : .primary)
            Spacer()
            Text(value.map { "\(NutrientRow.format($0, unit: unit)) \(unit)" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
        .font(emphasized ? .body.weight(.semibold) : .body)
        .accessibilityElement(children: .combine)
    }

    /// kcal and mg as whole numbers; grams with one decimal below 10.
    public nonisolated static func format(_ value: Double, unit: String, locale: Locale = .current) -> String {
        switch unit {
        case "kcal", "kJ", "mg", "ml":
            value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        default:
            abs(value) >= 10
                ? value.formatted(.number.precision(.fractionLength(0)).locale(locale))
                : value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
        }
    }
}

// MARK: - Source badge

/// Small capsule telling where a food comes from (FR-20).
public struct SourceBadge: View {
    public enum Kind: String, Sendable, CaseIterable {
        case custom, bundled, off, usda

        public var title: String {
            switch self {
            case .custom: String(localized: "Mine", bundle: .module, comment: "Source badge on the user's own foods")
            case .bundled: "USDA"
            case .off: "OFF"
            case .usda: "USDA"
            }
        }

        public var accessibilityTitle: String {
            switch self {
            case .custom: String(localized: "Your food", bundle: .module)
            case .bundled, .usda: "USDA FoodData Central"
            case .off: "Open Food Facts"
            }
        }

        var tint: Color {
            switch self {
            case .custom: .blue
            case .bundled, .usda: .green
            case .off: .orange
            }
        }
    }

    let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var body: some View {
        Text(kind.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, NL.Spacing.s - 2)
            .padding(.vertical, NL.Spacing.xxs)
            .foregroundStyle(kind.tint)
            .background(kind.tint.opacity(0.15), in: Capsule())
            .accessibilityLabel(kind.accessibilityTitle)
    }
}

// MARK: - Macro summary line

/// Compact "P 12 · C 30 · F 8" line used in list rows.
public struct MacroLine: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    public init(protein: Double, carbs: Double, fat: Double) {
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public var body: some View {
        HStack(spacing: NL.Spacing.s) {
            item(.protein, protein)
            item(.carbs, carbs)
            item(.fat, fat)
        }
        .font(NL.Typography.caption)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.macros(protein: protein, carbs: carbs, fat: fat))
    }

    private func item(_ macro: Macro, _ value: Double) -> some View {
        HStack(spacing: NL.Spacing.xxs) {
            Circle().fill(macro.color).frame(width: 6, height: 6)
            Text(verbatim: "\(macro.shortTitle) \(NutrientRow.format(value, unit: "g"))")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Empty & error states

public struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    public init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
    }
}

public struct ErrorStateView: View {
    let message: String
    let retry: (() -> Void)?

    public init(_ message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Something went wrong", bundle: .module), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button(String(localized: "Try again", bundle: .module), action: retry).buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Previews

#Preview("Components – light") {
    ComponentsGallery()
}

#Preview("Components – dark, XXL") {
    ComponentsGallery()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.xxxLarge)
}

struct ComponentsGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NL.Spacing.l) {
                HStack(spacing: NL.Spacing.l) {
                    EnergyRing(consumed: 1250, target: 2000).frame(width: 120, height: 120)
                    EnergyRing(consumed: 2300, target: 2000).frame(width: 120, height: 120)
                }
                MacroBar(macro: .protein, value: 120, target: 160)
                MacroBar(macro: .carbs, value: 260, target: 220)
                MacroBar(macro: .fat, value: 40, target: nil)
                NutrientRow("Energy", value: 189.5, unit: "kcal", emphasized: true)
                NutrientRow("of which sugars", value: 4.46, indent: true)
                NutrientRow("Fiber", value: nil)
                HStack { ForEach(SourceBadge.Kind.allCases, id: \.self) { SourceBadge($0) } }
                MacroLine(protein: 12, carbs: 30.4, fat: 8)
                EmptyStateView("No foods yet", systemImage: "fork.knife", message: "Create your first food.")
            }
            .padding()
        }
    }
}
