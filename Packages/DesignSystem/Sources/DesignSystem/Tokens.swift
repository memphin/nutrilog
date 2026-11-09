import SwiftUI

/// Design tokens. All colors are system-adaptive (light/dark) and work with Liquid Glass materials.
public enum NL {
    // MARK: Colors

    public enum Palette {
        public static let protein = Color.teal
        public static let carbs = Color.orange
        public static let fat = Color.pink
        public static let energy = Color.green
        public static let over = Color.red
        public static let fiber = Color.brown
        public static let water = Color.cyan
        public static let secondaryText = Color.secondary
        public static let track = Color.secondary.opacity(0.18)
        /// Small trend charts (the dashboard's 7-day sparklines) of metrics without a color of their own.
        public static let trend = Color.accentColor
    }

    // MARK: Spacing (4-pt grid)

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let s: CGFloat = 8
        public static let m: CGFloat = 14
        public static let l: CGFloat = 22
    }

    // MARK: Typography — text styles only, so Dynamic Type scales everything.

    public enum Typography {
        public static let largeNumber = Font.system(.largeTitle, design: .rounded).weight(.bold)
        public static let number = Font.system(.title3, design: .rounded).weight(.semibold)
        public static let smallNumber = Font.system(.subheadline, design: .rounded).weight(.medium)
        public static let label = Font.subheadline
        public static let caption = Font.caption
    }
}

/// The three macros, with their color and display name.
public enum Macro: String, CaseIterable, Sendable, Identifiable {
    case protein, carbs, fat

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }

    public var shortTitle: String {
        switch self {
        case .protein: "P"
        case .carbs: "C"
        case .fat: "F"
        }
    }

    public var color: Color {
        switch self {
        case .protein: NL.Palette.protein
        case .carbs: NL.Palette.carbs
        case .fat: NL.Palette.fat
        }
    }
}
