import Foundation
import Testing
@testable import Core

struct CaffeineModelTests {
    let model = CaffeineModel(halfLifeHours: 5)
    let t0 = Date(timeIntervalSince1970: 1_794_200_000)

    func at(hours: Double) -> Date {
        t0.addingTimeInterval(hours * 3600)
    }

    var ka: Double {
        CaffeineModel.absorptionRatePerHour
    }

    var ke: Double {
        log(2.0) / 5
    }

    @Test func `nothing before the dose and nothing at the moment of the dose`() {
        let dose = CaffeineDose(mg: 100, at: t0)
        #expect(model.amount(of: dose, at: at(hours: -1)) == 0)
        #expect(model.amount(of: dose, at: at(hours: -0.001)) == 0)
        #expect(model.amount(of: dose, at: t0) == 0)
        #expect(model.amount(at: at(hours: -2), doses: [dose]) == 0)
    }

    @Test func `a single dose peaks about 45 minutes after it`() {
        let dose = CaffeineDose(mg: 100, at: t0)
        let peakMinutes = model.hoursToPeak * 60
        #expect(peakMinutes > 40 && peakMinutes < 55)
        let peak = model.amount(of: dose, at: at(hours: model.hoursToPeak))
        #expect(peak > model.amount(of: dose, at: at(hours: model.hoursToPeak - 10.0 / 60)))
        #expect(peak > model.amount(of: dose, at: at(hours: model.hoursToPeak + 10.0 / 60)))
        // Nearly all of it is absorbed by then, little is eliminated yet.
        #expect(peak > 85 && peak < 95)
        // The sampled curve's maximum is at the analytic peak.
        let curve = model.curve(from: t0, to: at(hours: 3), step: 60, doses: [dose])
        let sampledPeak = curve.max { $0.mg < $1.mg }!
        #expect(abs(sampledPeak.date.timeIntervalSince(at(hours: model.hoursToPeak))) <= 60)
    }

    @Test func `after one half-life past absorption about half is left`() {
        let dose = CaffeineDose(mg: 100, at: t0)
        let later = model.amount(of: dose, at: at(hours: 15))
        let earlier = model.amount(of: dose, at: at(hours: 10))
        #expect(abs(later / earlier - 0.5) < 1e-9)
        // At t = t½ the absorption delay leaves slightly more than half: D · ka/(ka−ke) · ½.
        let fiveHours = model.amount(of: dose, at: at(hours: 5))
        #expect(abs(fiveHours - 100 * ka / (ka - ke) * 0.5) < 0.01)
        #expect(fiveHours > 50 && fiveHours < 53)
    }

    @Test func `doses add up`() {
        let morning = CaffeineDose(mg: 95, at: t0)
        let noon = CaffeineDose(mg: 64, at: at(hours: 4))
        for hours in [0.5, 3.0, 4.5, 9.0] {
            let total = model.amount(at: at(hours: hours), doses: [morning, noon])
            let separate = model.amount(of: morning, at: at(hours: hours)) + model.amount(of: noon, at: at(hours: hours))
            #expect(abs(total - separate) < 1e-12)
        }
        // A dose after the moment adds nothing yet.
        #expect(model.amount(at: at(hours: 3), doses: [morning, noon]) == model.amount(of: morning, at: at(hours: 3)))
        #expect(model.amount(at: t0, doses: []) == 0)
    }

    @Test func `invalid doses count as nothing`() {
        #expect(model.amount(of: CaffeineDose(mg: 0, at: t0), at: at(hours: 1)) == 0)
        #expect(model.amount(of: CaffeineDose(mg: -50, at: t0), at: at(hours: 1)) == 0)
        #expect(model.amount(of: CaffeineDose(mg: .infinity, at: t0), at: at(hours: 1)) == 0)
        #expect(model.amount(of: CaffeineDose(mg: .nan, at: t0), at: at(hours: 1)) == 0)
    }

    @Test func `curve samples every step and always ends at the end`() {
        let dose = CaffeineDose(mg: 100, at: t0)
        let even = model.curve(from: t0, to: at(hours: 1), step: 900, doses: [dose])
        #expect(even.map(\.date) == [0, 0.25, 0.5, 0.75, 1].map { at(hours: $0) })
        #expect(even.first?.mg == 0)
        #expect(even[2].mg == model.amount(of: dose, at: at(hours: 0.5)))
        let uneven = model.curve(from: t0, to: at(hours: 50.0 / 60), step: 900, doses: [dose])
        #expect(uneven.map(\.date) == [0, 15, 30, 45, 50].map { at(hours: $0 / 60) })
        #expect(model.curve(from: t0, to: t0, doses: [dose]).count == 1)
        #expect(model.curve(from: at(hours: 1), to: t0, doses: [dose]).isEmpty)
    }

    @Test func `first time below matches the analytic crossing`() throws {
        let dose = CaffeineDose(mg: 100, at: t0)
        let below = try #require(model.firstTimeBelow(threshold: 50, after: t0, doses: [dose]))
        // Long after absorption: D · ka/(ka−ke) · e^(−ke·t) = 50.
        let expected = at(hours: log(2 * ka / (ka - ke)) / ke)
        #expect(abs(below.timeIntervalSince(expected)) <= 2)
        #expect(model.amount(at: below, doses: [dose]) < 50)
        #expect(model.amount(at: below.addingTimeInterval(-5), doses: [dose]) >= 50)
        // Asking from a later moment while still above gives the same answer.
        let fromLater = try #require(model.firstTimeBelow(threshold: 50, after: at(hours: 2), doses: [dose]))
        #expect(abs(fromLater.timeIntervalSince(below)) <= 2)
    }

    @Test func `first time below is now when already below and nothing lifts it again`() {
        let now = at(hours: 12)
        #expect(model.firstTimeBelow(threshold: 50, after: now, doses: []) == now)
        #expect(model.firstTimeBelow(threshold: 50, after: now, doses: [CaffeineDose(mg: 100, at: t0)]) == now)
        // Below the threshold during the whole absorption of a small dose: never reaches it.
        #expect(model.firstTimeBelow(threshold: 50, after: t0, doses: [CaffeineDose(mg: 40, at: t0)]) == t0)
    }

    @Test func `a later dose pushes the safe time back`() throws {
        let now = at(hours: 12) // the morning coffee is mostly gone
        let evening = CaffeineDose(mg: 95, at: at(hours: 14))
        let doses = [CaffeineDose(mg: 95, at: t0), evening]
        let below = try #require(model.firstTimeBelow(threshold: 50, after: now, doses: doses))
        #expect(below > evening.at.addingTimeInterval(model.hoursToPeak * 3600))
        #expect(model.amount(at: below, doses: doses) < 50)
        #expect(model.amount(at: below.addingTimeInterval(-5), doses: doses) >= 50)
    }

    @Test func `first time below gives up beyond 48 hours and on a zero threshold`() {
        let slow = CaffeineModel(halfLifeHours: 15)
        // 10 g with t½ 15 h needs ~200 h to fall under 1 mg.
        #expect(slow.firstTimeBelow(threshold: 1, after: t0, doses: [CaffeineDose(mg: 10000, at: t0)]) == nil)
        #expect(model.firstTimeBelow(threshold: 0, after: t0, doses: [CaffeineDose(mg: 100, at: t0)]) == nil)
        #expect(model.firstTimeBelow(threshold: -1, after: t0, doses: []) == nil)
    }

    @Test func `equal absorption and elimination rates use the limit`() {
        let degenerate = CaffeineModel(halfLifeHours: log(2.0) / CaffeineModel.absorptionRatePerHour)
        let dose = CaffeineDose(mg: 100, at: t0)
        // D · ka · t · e^(−ka·t), at its peak t = 1/ka: D / e.
        #expect(abs(degenerate.hoursToPeak - 1 / ka) < 1e-12)
        let atPeak = degenerate.amount(of: dose, at: at(hours: 1 / ka))
        #expect(abs(atPeak - 100 / M_E) < 1e-6)
        #expect(atPeak.isFinite)
        // Continuous with a half-life just next to it.
        let nearby = CaffeineModel(halfLifeHours: log(2.0) / CaffeineModel.absorptionRatePerHour * (1 + 1e-5))
        for hours in [0.1, 0.5, 2.0] {
            let a = degenerate.amount(of: dose, at: at(hours: hours))
            let b = nearby.amount(of: dose, at: at(hours: hours))
            #expect(abs(a - b) < 1e-3)
        }
    }
}

struct CaffeineMetabolismTests {
    @Test func `half-life from factors`() {
        #expect(CaffeineMetabolism().halfLifeHours == 5)
        #expect(CaffeineMetabolism(smoker: true).halfLifeHours == 3)
        #expect(CaffeineMetabolism(oralContraceptives: true).halfLifeHours == 10)
        #expect(CaffeineMetabolism(pregnant: true).halfLifeHours == 12.5)
        // Pill and pregnancy: the larger factor, not the product (25 h).
        #expect(CaffeineMetabolism(oralContraceptives: true, pregnant: true).halfLifeHours == 12.5)
        #expect(CaffeineMetabolism(smoker: true, oralContraceptives: true).halfLifeHours == 6)
        #expect(CaffeineMetabolism(smoker: true, pregnant: true).halfLifeHours == 7.5)
    }

    @Test func `override wins and everything is clamped`() {
        #expect(CaffeineMetabolism(smoker: true, overrideHours: 8).halfLifeHours == 8)
        #expect(CaffeineMetabolism(overrideHours: 0.5).halfLifeHours == 1.5)
        #expect(CaffeineMetabolism(overrideHours: 0).halfLifeHours == 1.5)
        #expect(CaffeineMetabolism(overrideHours: -3).halfLifeHours == 1.5)
        #expect(CaffeineMetabolism(overrideHours: 40).halfLifeHours == 15)
        #expect(CaffeineMetabolism(pregnant: true, overrideHours: .nan).halfLifeHours == 12.5) // unusable override ignored
        #expect(CaffeineMetabolism(overrideHours: .infinity).halfLifeHours == 5)
        #expect(CaffeineMetabolism(smoker: true, overrideHours: 4).model.halfLifeHours == 4)
    }

    @Test func `codable round trip`() throws {
        let value = CaffeineMetabolism(smoker: true, oralContraceptives: false, pregnant: true, overrideHours: 6.5)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CaffeineMetabolism.self, from: data) == value)
    }
}

struct CaffeineDrinkTests {
    @Test func `presets are unique and the defaults resolve`() {
        let ids = CaffeineDrink.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CaffeineDrink.all.allSatisfy { $0.mg > 0 && $0.servingMl > 0 && !$0.symbolName.isEmpty })
        #expect(CaffeineDrink.defaultQuickAdd.count == CaffeineDrink.defaultQuickAddIDs.count)
        #expect((3 ... 4).contains(CaffeineDrink.defaultQuickAdd.count))
        #expect(CaffeineDrink.preset(id: "espresso")?.mg == 64)
        #expect(CaffeineDrink.preset(id: "filter_coffee")?.mg == 95)
        #expect(CaffeineDrink.preset(id: "nope") == nil)
    }

    @Test func defaults() {
        #expect(CaffeineDefaults.sleepSafeThresholdMg == 50)
        #expect(CaffeineDefaults.dailyLimitMg == 400)
        #expect(CaffeineDefaults.defaultBedtimeMinutes == 1380)
    }
}
