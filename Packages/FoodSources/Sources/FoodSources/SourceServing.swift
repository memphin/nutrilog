/// Serving weights read from a source, shared by the source mappers (OFF, FDC).
public enum SourceServing {
    /// Servings heavier than this (g/ml) are garbage ("serving_quantity": 1e19) and count as no serving at all.
    public static let maximumAmount = 100_000.0

    /// `amount` when it is a usable serving weight (above 0, at most ``maximumAmount``), else `nil`.
    static func usable(_ amount: Double?) -> Double? {
        guard let amount, amount > 0, amount <= maximumAmount else { return nil }
        return amount
    }
}
