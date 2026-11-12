import Foundation
import Testing
@testable import DesignSystem

struct AccessibilityTextTests {
    let en = Locale(identifier: "en_US")
    let hr = Locale(identifier: "hr_HR")

    @Test func `progress labels`() {
        #expect(A11y.progress(label: "Protein", value: 120, target: 160, unit: "g", locale: en) == "Protein 120 of 160 grams")
        #expect(A11y.progress(label: "Fat", value: 40.4, target: nil, unit: "g", locale: en) == "Fat 40 grams")
        #expect(A11y.progress(label: "Sodium", value: 1500, target: 0, unit: "mg", locale: en) == "Sodium 1,500 milligrams")
        #expect(A11y.progress(label: "Water", value: 750, target: 2500, unit: "ml", locale: en) == "Water 750 of 2,500 millilitres")
        #expect(A11y.progress(label: "Energy", value: 10, target: nil, unit: "kJ", locale: en) == "Energy 10 kilojoules")
        #expect(A11y.progress(label: "X", value: 1, target: nil, unit: "pcs", locale: en) == "X 1 pcs")
    }

    @Test func `energy labels`() {
        #expect(A11y.energyRemaining(consumed: 750, target: 2000, locale: en) == "1,250 calories remaining of 2,000")
        #expect(A11y.energyRemaining(consumed: 2150, target: 2000, locale: en) == "150 calories over target of 2,000")
        #expect(A11y.energyRemaining(consumed: 900, target: nil, locale: en) == "900 calories eaten, no target set")
    }

    @Test func `energy labels speak kilojoules`() {
        #expect(A11y.energyRemaining(consumed: 3138, target: 8368, unit: "kJ", locale: en) == "5,230 kilojoules remaining of 8,368")
        #expect(A11y.energyRemaining(consumed: 9000, target: 8368, unit: "kJ", locale: en) == "632 kilojoules over target of 8,368")
        #expect(A11y.energyRemaining(consumed: 3766, target: nil, unit: "kJ", locale: en) == "3,766 kilojoules eaten, no target set")
        #expect(A11y.energyRemaining(consumed: 750, target: 2000, unit: "kcal", locale: en) == "1,250 calories remaining of 2,000")
    }

    @Test func `macro line label`() {
        #expect(A11y.macros(protein: 12, carbs: 30.4, fat: 1250, locale: en) == "Protein 12 grams, carbs 30 grams, fat 1,250 grams")
    }

    /// Numbers follow the locale: Croatian groups thousands with a dot. (The words stay English: the test bundle has
    /// no Croatian translations.)
    @Test func `numbers follow the locale`() {
        #expect(A11y.format(1250, locale: hr) == "1.250")
        #expect(A11y.format(1250, locale: en) == "1,250")
        #expect(A11y.progress(label: "Water", value: 750, target: 2500, unit: "ml", locale: hr) == "Water 750 of 2.500 millilitres")
        #expect(A11y.energyRemaining(consumed: 750, target: 2000, locale: hr) == "1.250 calories remaining of 2.000")
        #expect(A11y.macros(protein: 1500, carbs: 0, fat: 8, locale: hr) == "Protein 1.500 grams, carbs 0 grams, fat 8 grams")
    }
}

struct ProgressTests {
    @Test func `clamps and flags over`() {
        #expect(Progress(value: 50, target: 100) == Progress(value: 50, target: 100))
        #expect(Progress(value: 50, target: 100).fraction == 0.5)
        #expect(!Progress(value: 100, target: 100).isOver)
        #expect(Progress(value: 150, target: 100).fraction == 1)
        #expect(Progress(value: 150, target: 100).isOver)
        #expect(Progress(value: -5, target: 100).fraction == 0)
        #expect(Progress(value: 5, target: nil).fraction == 0)
        #expect(Progress(value: 5, target: 0).isOver == false)
    }
}

struct FormattingTests {
    let en = Locale(identifier: "en_US")

    @Test func `nutrient row formatting`() {
        #expect(NutrientRow.format(189.5, unit: "kcal", locale: en) == "190")
        #expect(NutrientRow.format(4.46, unit: "g", locale: en) == "4.5")
        #expect(NutrientRow.format(4.0, unit: "g", locale: en) == "4")
        #expect(NutrientRow.format(12.6, unit: "g", locale: en) == "13")
        #expect(NutrientRow.format(640.4, unit: "mg", locale: en) == "640")
    }

    @Test func `badges and macros`() {
        #expect(SourceBadge.Kind.bundled.title == "USDA")
        #expect(SourceBadge.Kind.off.accessibilityTitle == "Open Food Facts")
        #expect(SourceBadge.Kind.allCases.allSatisfy { !$0.title.isEmpty && !$0.accessibilityTitle.isEmpty })
        #expect(Macro.allCases.map(\.shortTitle) == ["P", "C", "F"])
        #expect(Macro.protein.title == "Protein")
        #expect(MacroBar.text(119.6, locale: en) == "120")
        #expect(MacroBar.text(1250, locale: Locale(identifier: "hr_HR")) == "1.250")
        #expect(NutrientRow.format(4.5, unit: "g", locale: Locale(identifier: "hr_HR")) == "4,5")
    }
}
