import Foundation

// Correlations (FR-53): how two daily or weekly measures move together. Pure statistics on plain pairs; which days
// pair up (lags, weeks, left-out days) is decided by the app's pair builder.

/// One observation: a day (or week) with both values.
public struct CorrelationPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// How strong a link is, from the size of Spearman's rho.
public enum CorrelationStrength: String, Hashable, Sendable, CaseIterable {
    /// |rho| < 0.1.
    case none
    /// 0.1 ≤ |rho| < 0.3.
    case weak
    /// 0.3 ≤ |rho| < 0.5.
    case moderate
    /// |rho| ≥ 0.5.
    case strong

    public init(rho: Double) {
        switch abs(rho) {
        case ..<0.1: self = .none
        case ..<0.3: self = .weak
        case ..<0.5: self = .moderate
        default: self = .strong
        }
    }
}

/// Positive: both go up together. Negative: one goes up as the other goes down.
public enum CorrelationDirection: String, Hashable, Sendable {
    case positive, negative
}

/// A least-squares line `y = slope · x + intercept`.
public struct LinearFit: Hashable, Sendable {
    public var slope: Double
    public var intercept: Double

    public func y(at x: Double) -> Double {
        slope * x + intercept
    }
}

/// The mean y of the points with the lowest x against those with the highest x — the plain-language side of a
/// correlation ("on days you drank 2.5 L or more, your HRV the next day was 6 ms higher than on days under 1.8 L").
///
/// The groups are a third of the points each, sorted by x, widened over ties: every point whose x equals the last x of
/// the low third is low too (and likewise for the high third), so "under `lowBelow`" and "`highFrom` or more" describe
/// the groups exactly.
public struct ThirdsComparison: Hashable, Sendable {
    /// The low group is every point with x below this (the smallest x above the low group).
    public var lowBelow: Double
    /// The high group is every point with x at or above this.
    public var highFrom: Double
    public var lowMeanY: Double
    public var highMeanY: Double
    public var lowCount: Int
    public var highCount: Int

    /// High minus low: positive when y is higher where x is high.
    public var difference: Double {
        highMeanY - lowMeanY
    }
}

public enum Correlation {
    /// Days with both values needed before a daily link is described.
    public static let minimumDailyPairs = 14
    /// Weeks with both values needed before a weekly link is described.
    public static let minimumWeeklyPairs = 6

    /// Ranks from 1, in the order of `values`; tied values share the average of the ranks they span.
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = Array(repeating: 0.0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count, values[order[end + 1]] == values[order[start]] {
                end += 1
            }
            // Positions start…end hold ranks start+1 … end+1.
            let rank = Double(start + end + 2) / 2
            for position in start ... end {
                ranks[order[position]] = rank
            }
            start = end + 1
        }
        return ranks
    }

    /// Pearson's correlation of two equally long series; nil with fewer than 3 values or when either side is constant.
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for (x, y) in zip(xs, ys) {
            let dx = x - meanX, dy = y - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return max(-1, min(1, covariance / (varianceX * varianceY).squareRoot()))
    }

    /// Spearman's rank correlation (Pearson's on the ranks, ties sharing their average rank); nil with fewer than
    /// 3 points or when either side never changes.
    public static func spearman(_ points: [CorrelationPoint]) -> Double? {
        guard points.count >= 3 else { return nil }
        return pearson(ranks(points.map(\.x)), ranks(points.map(\.y)))
    }

    /// The least-squares line through `points`; nil with fewer than 2 points or a single x value.
    public static func linearFit(_ points: [CorrelationPoint]) -> LinearFit? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var covariance = 0.0, varianceX = 0.0
        for point in points {
            covariance += (point.x - meanX) * (point.y - meanY)
            varianceX += (point.x - meanX) * (point.x - meanX)
        }
        guard varianceX > 0 else { return nil }
        let slope = covariance / varianceX
        return LinearFit(slope: slope, intercept: meanY - slope * meanX)
    }

    /// The lowest third by x against the highest third (see `ThirdsComparison`); nil with fewer than 3 points or when
    /// ties leave the two groups overlapping (x hardly varies).
    public static func thirds(_ points: [CorrelationPoint]) -> ThirdsComparison? {
        let third = points.count / 3
        guard third >= 1 else { return nil }
        let xs = points.map(\.x).sorted()
        let lowMax = xs[third - 1]
        let highFrom = xs[xs.count - third]
        guard lowMax < highFrom, let lowBelow = xs.first(where: { $0 > lowMax }) else { return nil }
        let low = points.filter { $0.x <= lowMax }.map(\.y)
        let high = points.filter { $0.x >= highFrom }.map(\.y)
        return ThirdsComparison(
            lowBelow: lowBelow, highFrom: highFrom,
            lowMeanY: low.reduce(0, +) / Double(low.count), highMeanY: high.reduce(0, +) / Double(high.count),
            lowCount: low.count, highCount: high.count,
        )
    }
}

/// Everything a correlation card or detail shows, from the paired values.
public struct CorrelationResult: Hashable, Sendable {
    public var points: [CorrelationPoint]
    /// Pairs needed before a strength is given (`Correlation.minimumDailyPairs` or `minimumWeeklyPairs`).
    public var minimumCount: Int
    /// Spearman's rho; nil with fewer than 3 points or when a side never changes.
    public var rho: Double?
    public var thirds: ThirdsComparison?
    /// The line drawn through the scatter plot.
    public var fit: LinearFit?

    public init(points: [CorrelationPoint], minimumCount: Int) {
        self.points = points
        self.minimumCount = minimumCount
        rho = Correlation.spearman(points)
        thirds = Correlation.thirds(points)
        fit = Correlation.linearFit(points)
    }

    public var count: Int {
        points.count
    }

    public var hasEnoughData: Bool {
        count >= minimumCount
    }

    /// Nil below the minimum sample ("not enough data"). With enough data, a side that never changes has no clear link.
    public var strength: CorrelationStrength? {
        guard hasEnoughData else { return nil }
        return rho.map(CorrelationStrength.init(rho:)) ?? CorrelationStrength.none
    }

    /// Nil below the minimum sample and when there is no clear link.
    public var direction: CorrelationDirection? {
        guard let strength, strength != .none, let rho else { return nil }
        return rho > 0 ? .positive : .negative
    }
}
