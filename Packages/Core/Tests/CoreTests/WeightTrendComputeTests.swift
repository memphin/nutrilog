import Foundation
import Testing
@testable import Core

struct WeightTrendComputeTests {
    let start = LocalDay("2026-09-01")!

    private func samples(_ count: Int, _ weight: (Int) -> Double?) -> [LocalDay: Double] {
        var result: [LocalDay: Double] = [:]
        for index in 0 ..< count {
            if let kg = weight(index) {
                result[start.adding(days: index)] = kg
            }
        }
        return result
    }

    @Test func `steady loss: the trend follows with the same slope`() throws {
        // 0.1 kg a day from 90 kg.
        let points = WeightTrend.compute(samples: samples(60) { 90 - 0.1 * Double($0) })
        #expect(points.count == 60)
        #expect(points[0].trendKg == 90)
        #expect(points.allSatisfy { !$0.isOutlier })
        // After the warm-up the trend falls 0.1 kg a day, lagging (1 − α) / α = 9 days behind.
        let slope = points[59].trendKg - points[58].trendKg
        #expect(abs(slope - -0.1) < 0.002)
        #expect(try abs(points[59].trendKg - (#require(points[59].weightKg) + 0.9)) < 0.01)
        // The trend is smoother than the weigh-ins but stays above them while losing.
        #expect(points.dropFirst().allSatisfy { $0.trendKg > $0.weightKg! })
    }

    @Test func `plateau with noise: the trend stays near the mean`() throws {
        let noise = [0.4, -0.3, 0.2, -0.5, 0.1, 0.3, -0.2]
        let points = WeightTrend.compute(samples: samples(42) { 80 + noise[$0 % 7] })
        #expect(points.allSatisfy { !$0.isOutlier }) // ±0.5 kg is well under 2.5 %
        for point in points.suffix(14) {
            #expect(abs(point.trendKg - 80) < 0.15)
        }
        // Much less spread than the raw values.
        let spread = try #require(points.suffix(14).map(\.trendKg).max()) - #require(points.suffix(14).map(\.trendKg).min())
        #expect(spread < 0.2)
    }

    @Test func `missing week: the trend is carried forward, then continues`() throws {
        // Weigh-ins on days 0–9 and 17–25; days 10–16 are missing.
        let points = WeightTrend.compute(samples: samples(26) { (10 ..< 17).contains($0) ? nil : 80 - 0.1 * Double($0) })
        #expect(points.count == 26)
        let carried = points[9].trendKg
        for index in 10 ..< 17 {
            #expect(points[index].trendKg == carried)
            #expect(points[index].weightKg == nil)
            #expect(!points[index].isOutlier)
        }
        // The first weigh-in after the gap is taken normally (no jump check after more than 3 days).
        #expect(!points[17].isOutlier)
        #expect(try abs(points[17].trendKg - (carried + 0.1 * (#require(points[17].weightKg) - carried))) < 1e-9)
    }

    @Test func `water-weight spike is down-weighted`() throws {
        // Flat 80 kg, one morning at 82.5 kg (+3.1 %).
        let points = WeightTrend.compute(samples: samples(30) { $0 == 20 ? 82.5 : 80 })
        #expect(points[20].isOutlier)
        #expect(points.count(where: \.isOutlier) == 1) // the return to 80 kg is not a jump
        #expect(abs(points[20].trendKg - (80 + 0.1 * 0.25 * 2.5)) < 1e-9) // 80.0625 instead of 80.25
        #expect(points[21].trendKg < points[20].trendKg)
        let plain = WeightTrend.ema(samples(30) { $0 == 20 ? 82.5 : 80 }, through: start.adding(days: 29))
        #expect(try #require(plain[start.adding(days: 20)]) - 80 > 3 * (points[20].trendKg - 80))
    }

    @Test func `a jump that stays is accepted on the second day`() {
        // A real change of level (new scale): 80 → 83 kg and it stays there.
        let points = WeightTrend.compute(samples: samples(30) { $0 < 10 ? 80 : 83 })
        #expect(points[10].isOutlier)
        #expect(!points[11].isOutlier)
        #expect(points.count(where: \.isOutlier) == 1)
        #expect(points[29].trendKg > 82.5) // caught up
    }

    @Test func `spikes two days in a row at different levels are both down-weighted`() {
        let points = WeightTrend.compute(samples: samples(15) { $0 == 8 ? 83 : $0 == 9 ? 77 : 80 })
        #expect(points[8].isOutlier)
        #expect(points[9].isOutlier)
        #expect(!points[10].isOutlier)
    }

    @Test func `empty input, range and helpers`() {
        #expect(WeightTrend.compute(samples: [:]).isEmpty)
        #expect(WeightTrend.compute(samples: [start: 80], through: start.previous).isEmpty)
        let extended = WeightTrend.compute(samples: [start: 80], through: start.adding(days: 3))
        #expect(extended.map(\.trendKg) == [80, 80, 80, 80])
        #expect(WeightTrend.trendByDay([start: 80, start.next: 81])[start.next] == 80.1)
        #expect(WeightTrend.defaultAlpha == 0.1)
        let weights = [
            DayWeight(day: start, kg: 80, bodyFatPct: nil, isManual: false),
            DayWeight(day: start.next, kg: nil, bodyFatPct: 20, isManual: false),
        ]
        #expect(WeightTrend.samples(weights) == [start: 80])
    }

    @Test func `matches the plain EMA when nothing jumps`() throws {
        let data = samples(40) { 75 + sin(Double($0)) * 0.6 }
        let plain = WeightTrend.ema(data, through: start.adding(days: 39))
        let robust = WeightTrend.trendByDay(data)
        for (day, value) in plain {
            #expect(try abs(value - #require(robust[day])) < 1e-9)
        }
    }
}
