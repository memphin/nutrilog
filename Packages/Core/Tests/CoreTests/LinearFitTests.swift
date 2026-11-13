import Foundation
import Testing
@testable import Core

struct LinearFitTests {
    private func points(_ xs: [Double], _ ys: [Double]) -> [(x: Double, y: Double)] {
        zip(xs, ys).map { (x: $0, y: $1) }
    }

    private func close(_ value: Double, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        abs(value - expected) < tolerance
    }

    @Test func `least squares recovers a straight line`() throws {
        let fit = try #require(LinearFit(points([1, 2, 3, 4], [3, 5, 7, 9])))
        #expect(close(fit.slope, 2))
        #expect(close(fit.intercept, 1))
        #expect(close(fit.y(at: 10), 21))
    }

    @Test func `least squares through scattered points`() throws {
        // x̄ = 2, ȳ = 2; Σ(dx·dy) = 3, Σdx² = 2 → slope 1.5, intercept −1.
        let fit = try #require(LinearFit(points([1, 2, 3], [0, 3, 3])))
        #expect(close(fit.slope, 1.5))
        #expect(close(fit.intercept, -1))
    }

    @Test func `no line without two different x values`() {
        #expect(LinearFit(points([1], [1])) == nil)
        #expect(LinearFit(points([2, 2, 2], [1, 2, 3])) == nil)
    }
}
