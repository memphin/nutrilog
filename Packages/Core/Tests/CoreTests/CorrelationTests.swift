import Foundation
import Testing
@testable import Core

struct CorrelationTests {
    private func points(_ xs: [Double], _ ys: [Double]) -> [CorrelationPoint] {
        zip(xs, ys).map { CorrelationPoint(x: $0, y: $1) }
    }

    private func close(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < tolerance
    }

    // MARK: Ranks and Spearman

    @Test func `ties share the average of their ranks`() {
        #expect(Correlation.ranks([10, 20, 20, 30, 20]) == [1, 3, 3, 5, 3])
        #expect(Correlation.ranks([3, 1, 2]) == [3, 1, 2])
        #expect(Correlation.ranks([]) == [])
    }

    @Test func `a monotone relation is a perfect rank correlation, even when it is not a straight line`() {
        let xs: [Double] = [1, 2, 3, 4, 5, 6]
        #expect(close(Correlation.spearman(points(xs, xs.map { $0 * $0 * $0 })), 1))
        #expect(close(Correlation.spearman(points(xs, xs.map { 100 - exp($0) })), -1))
    }

    @Test func `spearman matches the textbook example`() {
        // IQ against hours of TV per week (the Wikipedia example): rho = −29/165.
        let iq: [Double] = [106, 86, 100, 101, 99, 103, 97, 113, 112, 110]
        let tv: [Double] = [7, 0, 27, 50, 28, 29, 20, 12, 6, 17]
        #expect(close(Correlation.spearman(points(iq, tv)), -29.0 / 165))
    }

    @Test func `spearman uses average ranks for ties`() {
        // Ranks x = 1, 2.5, 2.5, 4 and y = 1, 3, 2, 4: Pearson of the ranks is 4.5 / √(4.5 × 5) = √0.9.
        #expect(close(Correlation.spearman(points([1, 2, 2, 3], [1, 3, 2, 4])), sqrt(0.9)))
    }

    @Test func `spearman needs three points and two sides that vary`() {
        #expect(Correlation.spearman([]) == nil)
        #expect(Correlation.spearman(points([1, 2], [1, 2])) == nil)
        #expect(Correlation.spearman(points([5, 5, 5, 5], [1, 2, 3, 4])) == nil)
        #expect(Correlation.spearman(points([1, 2, 3, 4], [7, 7, 7, 7])) == nil)
        #expect(Correlation.spearman(points([1, 2, 3], [1, 3, 2])) != nil)
    }

    // MARK: Strength

    @Test func `strength follows the size of rho, whatever its sign`() {
        #expect(CorrelationStrength(rho: 0) == .none)
        #expect(CorrelationStrength(rho: 0.099) == .none)
        #expect(CorrelationStrength(rho: -0.099) == .none)
        #expect(CorrelationStrength(rho: 0.1) == .weak)
        #expect(CorrelationStrength(rho: -0.29) == .weak)
        #expect(CorrelationStrength(rho: 0.3) == .moderate)
        #expect(CorrelationStrength(rho: -0.49) == .moderate)
        #expect(CorrelationStrength(rho: 0.5) == .strong)
        #expect(CorrelationStrength(rho: -1) == .strong)
    }

    // MARK: Linear fit

    @Test func `least squares recovers a straight line`() throws {
        let fit = try #require(Correlation.linearFit(points([1, 2, 3, 4], [3, 5, 7, 9])))
        #expect(close(fit.slope, 2))
        #expect(close(fit.intercept, 1))
        #expect(close(fit.y(at: 10), 21))
    }

    @Test func `least squares through scattered points`() throws {
        // x̄ = 2, ȳ = 2; Σ(dx·dy) = 3, Σdx² = 2 → slope 1.5, intercept −1.
        let fit = try #require(Correlation.linearFit(points([1, 2, 3], [0, 3, 3])))
        #expect(close(fit.slope, 1.5))
        #expect(close(fit.intercept, -1))
    }

    @Test func `no line without two different x values`() {
        #expect(Correlation.linearFit(points([1], [1])) == nil)
        #expect(Correlation.linearFit(points([2, 2, 2], [1, 2, 3])) == nil)
    }

    // MARK: Top against bottom third

    @Test func `thirds compare the mean y of the lowest and highest third by x`() throws {
        let xs: [Double] = [5, 1, 9, 3, 7, 2, 8, 4, 6]
        let thirds = try #require(Correlation.thirds(points(xs, xs.map { $0 * 10 })))
        #expect(thirds.lowCount == 3 && thirds.highCount == 3)
        #expect(thirds.lowMeanY == 20 && thirds.highMeanY == 80)
        #expect(thirds.difference == 60)
        // Low: x under 4 (the smallest x above the low group); high: x of 7 or more.
        #expect(thirds.lowBelow == 4 && thirds.highFrom == 7)
    }

    @Test func `thirds of a count that does not divide by three leave the remainder in the middle`() throws {
        let xs: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        let thirds = try #require(Correlation.thirds(points(xs, xs.map { -$0 })))
        #expect(thirds.lowCount == 3 && thirds.highCount == 3)
        #expect(thirds.lowMeanY == -2 && thirds.highMeanY == -10)
        #expect(thirds.difference == -8)
        #expect(thirds.lowBelow == 4 && thirds.highFrom == 9)
    }

    @Test func `tied x values at a boundary all join that group, so the thresholds stay true`() throws {
        // Lowest third by position is 1, 2, 2 — but every 2 is "under 3", so all five 2s count as low.
        let xs: [Double] = [1, 2, 2, 2, 2, 2, 3, 4, 5]
        let thirds = try #require(Correlation.thirds(points(xs, [0, 1, 1, 1, 1, 1, 5, 6, 7])))
        #expect(thirds.lowCount == 6 && thirds.highCount == 3)
        #expect(thirds.lowBelow == 3 && thirds.highFrom == 3)
        #expect(close(thirds.lowMeanY, 5.0 / 6))
        #expect(thirds.highMeanY == 6)
    }

    @Test func `no thirds without three points or enough spread in x`() {
        #expect(Correlation.thirds(points([1, 2], [1, 2])) == nil)
        #expect(Correlation.thirds(points([4, 4, 4, 4, 4, 4], [1, 2, 3, 4, 5, 6])) == nil)
        #expect(Correlation.thirds(points([1, 1, 1, 1, 1, 1, 1, 1, 2], [1, 2, 3, 4, 5, 6, 7, 8, 9])) == nil)
        #expect(Correlation.thirds(points([1, 2, 3], [5, 6, 7])) != nil)
    }

    // MARK: Result

    @Test func `below the minimum sample there is no strength`() {
        let few = CorrelationResult(points: points([1, 2, 3, 4, 5], [1, 2, 3, 4, 5]), minimumCount: 6)
        #expect(!few.hasEnoughData)
        #expect(few.count == 5)
        #expect(few.strength == nil && few.direction == nil)
        // The numbers are still there for the scatter plot.
        #expect(few.rho != nil && few.fit != nil)
    }

    @Test func `enough data gives a strength and a direction`() {
        let xs = (1 ... 14).map(Double.init)
        let rising = CorrelationResult(
            points: points(xs, xs.map { $0 + ($0.truncatingRemainder(dividingBy: 2) == 0 ? 3 : -3) }),
            minimumCount: 14,
        )
        #expect(rising.hasEnoughData)
        #expect(rising.strength == .strong && rising.direction == .positive)
        let falling = CorrelationResult(points: points(xs, xs.map { -$0 }), minimumCount: 14)
        #expect(falling.strength == .strong && falling.direction == .negative)
        #expect(falling.thirds?.difference ?? 0 < 0)
    }

    @Test func `a side that never changes is no clear link`() {
        let xs = (1 ... 6).map(Double.init)
        let flat = CorrelationResult(points: points(xs, Array(repeating: 7, count: 6)), minimumCount: 6)
        #expect(flat.hasEnoughData)
        #expect(flat.rho == nil)
        #expect(flat.strength == CorrelationStrength.none && flat.direction == nil)
    }

    @Test func `minimum samples: two weeks of days, six weeks`() {
        #expect(Correlation.minimumDailyPairs == 14)
        #expect(Correlation.minimumWeeklyPairs == 6)
    }

    // MARK: Logged days

    @Test func `a day counts as logged with three entries or when marked complete`() {
        let day = LocalDay("2026-11-11")!
        let meal = Nutrients(kcal: 500, proteinG: 20, carbsG: 60, fatG: 15)
        #expect(!DayStats(day: day, intake: meal, entryCount: 2).isLogged)
        #expect(DayStats(day: day, intake: meal, entryCount: 3).isLogged)
        #expect(DayStats(day: day, intake: meal, entryCount: 1, isComplete: true).isLogged)
        #expect(!DayStats(day: day).isLogged)
    }
}
