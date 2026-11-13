import Foundation

public extension Double {
    /// The nearest multiple of `step` (halves away from zero), e.g. 2347 → 2350 for a step of 10.
    func rounded(toMultipleOf step: Double) -> Double {
        (self / step).rounded() * step
    }
}

public extension String {
    /// The text without leading and trailing whitespace and newlines; `nil` when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension String? {
    /// `String.trimmedNonEmpty` of the text; `nil` for `nil`.
    var trimmedNonEmpty: String? {
        self?.trimmedNonEmpty
    }
}
