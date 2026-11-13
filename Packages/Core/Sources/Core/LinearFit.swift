import Foundation

/// A least-squares line `y = slope · x + intercept`.
public struct LinearFit: Hashable, Sendable {
    public var slope: Double
    public var intercept: Double

    public func y(at x: Double) -> Double {
        slope * x + intercept
    }

    /// The least-squares line through `points`; nil with fewer than 2 points or a single x value.
    public init?(_ points: [(x: Double, y: Double)]) {
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
        slope = covariance / varianceX
        intercept = meanY - slope * meanX
    }
}
