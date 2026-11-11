import Foundation

// MARK: - Doses

/// One intake of caffeine: `mg` taken at `at` (a quick-add drink, or a diary entry with caffeine).
public struct CaffeineDose: Hashable, Sendable {
    public var mg: Double
    public var at: Date

    public init(mg: Double, at: Date) {
        self.mg = mg
        self.at = at
    }
}

/// One point of a caffeine curve: `mg` in the body at `date`.
public struct CaffeinePoint: Hashable, Sendable {
    public var date: Date
    public var mg: Double

    public init(date: Date, mg: Double) {
        self.date = date
        self.mg = mg
    }
}

// MARK: - Model

/// Caffeine in the body over time: a one-compartment pharmacokinetic model with first-order absorption and
/// elimination (the Bateman function), one curve per dose, summed (doses are independent; caffeine kinetics are
/// close to linear at dietary amounts).
///
/// For a dose `D` taken `t` hours ago:
///
///     amount(t) = D · ka / (ka − ke) · (e^(−ke·t) − e^(−ka·t))   for t ≥ 0, else 0
///
/// - `ke = ln 2 / t½` is the elimination rate (see ``CaffeineMetabolism`` for the half-life).
/// - `ka` = ``absorptionRatePerHour`` (4.6 /h, absorption half-time ≈ 9 min): oral caffeine is absorbed almost
///   completely within ~45 min, and with a 5 h half-life the curve peaks ≈ 45–50 min after the dose.
/// - Bioavailability is taken as 1 (oral caffeine is ~99 % bioavailable, no relevant first-pass effect), so the
///   result is the amount in the body in mg, not a plasma concentration (which would need the volume of
///   distribution, ~0.6 L/kg).
///
/// It's an estimate for "how much is still in me" and "when can I sleep", not a clinical tool: individual half-lives
/// vary several-fold.
public struct CaffeineModel: Hashable, Sendable {
    /// First-order absorption rate constant ka, per hour.
    public static let absorptionRatePerHour = 4.6

    /// Elimination half-life in hours (> 0).
    public var halfLifeHours: Double

    /// - Parameter halfLifeHours: must be positive and finite; ``CaffeineMetabolism/halfLifeHours`` always is.
    public init(halfLifeHours: Double = CaffeineMetabolism.baseHalfLifeHours) {
        precondition(halfLifeHours > 0 && halfLifeHours.isFinite, "half-life must be positive")
        self.halfLifeHours = halfLifeHours
    }

    /// Elimination rate constant ke = ln 2 / t½, per hour.
    public var eliminationRatePerHour: Double {
        M_LN2 / halfLifeHours
    }

    /// Hours from a dose to its peak: ln(ka/ke) / (ka − ke) (1 / ka when ka == ke).
    public var hoursToPeak: Double {
        let ka = Self.absorptionRatePerHour, ke = eliminationRatePerHour
        if Self.ratesCoincide(ka, ke) {
            return 1 / ka
        }
        return log(ka / ke) / (ka - ke)
    }

    /// Caffeine left in the body (mg) from `dose` at `date`; 0 before the dose.
    public func amount(of dose: CaffeineDose, at date: Date) -> Double {
        let hours = date.timeIntervalSince(dose.at) / 3600
        guard hours >= 0, dose.mg > 0, dose.mg.isFinite else { return 0 }
        let ka = Self.absorptionRatePerHour, ke = eliminationRatePerHour
        if Self.ratesCoincide(ka, ke) {
            // Limit of the Bateman function for ke → ka.
            return dose.mg * ka * hours * exp(-ka * hours)
        }
        return dose.mg * ka / (ka - ke) * (exp(-ke * hours) - exp(-ka * hours))
    }

    /// Total caffeine in the body (mg) at `date` from all `doses` (doses after `date` add nothing).
    public func amount(at date: Date, doses: some Sequence<CaffeineDose>) -> Double {
        doses.reduce(0) { $0 + amount(of: $1, at: date) }
    }

    /// The curve from `start` to `end` every `step` seconds; `end` itself is always the last point.
    /// Empty when `end < start`.
    public func curve(from start: Date, to end: Date, step: TimeInterval = 300, doses: [CaffeineDose]) -> [CaffeinePoint] {
        precondition(step > 0 && step.isFinite, "step must be positive")
        guard end >= start else { return [] }
        var points: [CaffeinePoint] = []
        var index = 0
        while true {
            let date = start.addingTimeInterval(Double(index) * step)
            guard date < end else { break }
            points.append(CaffeinePoint(date: date, mg: amount(at: date, doses: doses)))
            index += 1
        }
        points.append(CaffeinePoint(date: end, mg: amount(at: end, doses: doses)))
        return points
    }

    /// The first moment at or after `after` from which the amount stays below `threshold` for good — e.g. when it
    /// is "safe to sleep". Returns `after` itself when the amount is already below and no later dose lifts it to the
    /// threshold again; nil when it doesn't drop below within 48 h after the last dose's peak (or `threshold <= 0`,
    /// which is never undercut).
    ///
    /// Searches forward in 5-minute steps (a dose's peak is broad compared with that), then refines the last
    /// crossing by bisection to about a second. Past the last dose's peak every curve only falls, so the search can
    /// stop there + 48 h.
    public func firstTimeBelow(threshold: Double, after: Date, doses: [CaffeineDose]) -> Date? {
        guard threshold > 0, threshold.isFinite else { return nil }
        let relevant = doses.filter { $0.mg > 0 && $0.mg.isFinite }
        guard let lastDose = relevant.map(\.at).max() else { return after }
        let lastPeak = lastDose.addingTimeInterval(hoursToPeak * 3600)
        let end = max(after, lastPeak).addingTimeInterval(48 * 3600)
        let step: TimeInterval = 300

        // Last sampled time at or above the threshold.
        var lastAbove: Date?
        var index = 0
        while true {
            let date = min(after.addingTimeInterval(Double(index) * step), end)
            if amount(at: date, doses: relevant) >= threshold {
                lastAbove = date
            }
            if date >= end {
                break
            }
            index += 1
        }
        guard let lastAbove else { return after }
        guard lastAbove < end else { return nil }

        // Bisect between the last sample above and the next one (below).
        var low = lastAbove
        var high = min(lastAbove.addingTimeInterval(step), end)
        while high.timeIntervalSince(low) > 1 {
            let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            if amount(at: middle, doses: relevant) >= threshold {
                low = middle
            } else {
                high = middle
            }
        }
        return high
    }

    /// ka and ke equal (up to rounding): the general formula divides by ~0 there.
    private static func ratesCoincide(_ ka: Double, _ ke: Double) -> Bool {
        abs(ka - ke) <= 1e-9 * max(ka, ke)
    }
}

// MARK: - Half-life

/// What changes how fast someone clears caffeine, turned into a half-life for ``CaffeineModel``.
///
/// Sources (reviews of caffeine pharmacokinetics, e.g. Institute of Medicine 2001, "Caffeine for the Sustainment of
/// Mental Task Performance"; Nehlig 2018, "Interindividual Differences in Caffeine Metabolism"):
/// - Typical healthy adult: t½ ≈ 5 h (reported range about 1.5–9.5 h).
/// - Smoking induces CYP1A2, the main caffeine-metabolising enzyme, and shortens t½ by 30–50 % (×0.6 ≈ 3 h).
/// - Oral contraceptives inhibit CYP1A2 and about double t½.
/// - Pregnancy slows clearance progressively; late in pregnancy t½ reaches ~15 h (×2.5 here as a middle value).
///
/// Oral contraceptives and pregnancy don't occur together and both act by slowing CYP1A2, so the larger of the two
/// factors is used rather than their product. Smoking multiplies on top. The result is clamped to
/// ``halfLifeRange``; an explicit ``overrideHours`` wins over the factors (and is clamped too).
public struct CaffeineMetabolism: Hashable, Sendable, Codable {
    public static let baseHalfLifeHours = 5.0
    public static let smokerFactor = 0.6
    public static let oralContraceptivesFactor = 2.0
    public static let pregnancyFactor = 2.5
    public static let halfLifeRange: ClosedRange<Double> = 1.5 ... 15

    public var smoker: Bool
    public var oralContraceptives: Bool
    public var pregnant: Bool
    /// A half-life the user set themselves, in hours; nil to derive it from the factors.
    public var overrideHours: Double?

    public init(smoker: Bool = false, oralContraceptives: Bool = false, pregnant: Bool = false, overrideHours: Double? = nil) {
        self.smoker = smoker
        self.oralContraceptives = oralContraceptives
        self.pregnant = pregnant
        self.overrideHours = overrideHours
    }

    /// The effective half-life in hours, always within ``halfLifeRange``.
    public var halfLifeHours: Double {
        if let overrideHours, overrideHours.isFinite {
            return Self.clamped(overrideHours)
        }
        var hours = Self.baseHalfLifeHours
        if smoker {
            hours *= Self.smokerFactor
        }
        hours *= max(
            oralContraceptives ? Self.oralContraceptivesFactor : 1,
            pregnant ? Self.pregnancyFactor : 1,
        )
        return Self.clamped(hours)
    }

    /// The model with this half-life.
    public var model: CaffeineModel {
        CaffeineModel(halfLifeHours: halfLifeHours)
    }

    private static func clamped(_ hours: Double) -> Double {
        min(max(hours, halfLifeRange.lowerBound), halfLifeRange.upperBound)
    }
}

// MARK: - Defaults

public enum CaffeineDefaults {
    /// Below this amount in the body (mg) caffeine is unlikely to disturb sleep — the "sleep safe" line.
    public static let sleepSafeThresholdMg = 50.0
    /// Daily intake considered safe for healthy adults (EFSA 2015, FDA): 400 mg.
    public static let dailyLimitMg = 400.0
    /// Default bedtime in minutes from midnight (23:00).
    public static let defaultBedtimeMinutes = 23 * 60
}

// MARK: - Drink presets

/// A preset drink for caffeine quick-add. Amounts are typical values per serving (USDA FoodData Central, EFSA);
/// real drinks vary a lot with brew strength and brand.
public struct CaffeineDrink: Hashable, Sendable, Identifiable {
    /// Stable id, stored with each quick-add entry (`caffeine_entry.drink_id`) and in the quick-add setting.
    public let id: String
    /// English display name.
    public let name: String
    /// Caffeine per serving in mg.
    public let mg: Double
    /// The serving the amount refers to, in ml.
    public let servingMl: Double
    /// SF Symbol for the UI.
    public let symbolName: String

    public init(id: String, name: String, mg: Double, servingMl: Double, symbolName: String) {
        self.id = id
        self.name = name
        self.mg = mg
        self.servingMl = servingMl
        self.symbolName = symbolName
    }

    /// Single shot (~30 ml).
    public static let espresso = CaffeineDrink(
        id: "espresso", name: "Espresso", mg: 64, servingMl: 30, symbolName: "cup.and.saucer.fill",
    )
    /// Brewed / filter coffee, one cup (~240 ml).
    public static let filterCoffee = CaffeineDrink(
        id: "filter_coffee", name: "Filter coffee", mg: 95, servingMl: 240, symbolName: "mug.fill",
    )
    public static let blackTea = CaffeineDrink(
        id: "black_tea", name: "Black tea", mg: 47, servingMl: 240, symbolName: "leaf.fill",
    )
    public static let greenTea = CaffeineDrink(
        id: "green_tea", name: "Green tea", mg: 28, servingMl: 240, symbolName: "leaf.fill",
    )
    /// One can (330 ml).
    public static let cola = CaffeineDrink(
        id: "cola", name: "Cola", mg: 33, servingMl: 330, symbolName: "takeoutbag.and.cup.and.straw.fill",
    )
    /// One can (250 ml).
    public static let energyDrink = CaffeineDrink(
        id: "energy_drink", name: "Energy drink", mg: 80, servingMl: 250, symbolName: "bolt.fill",
    )
    /// About 2 g of powder (1 tsp) whisked into a cup.
    public static let matcha = CaffeineDrink(
        id: "matcha", name: "Matcha", mg: 70, servingMl: 240, symbolName: "leaf.fill",
    )

    /// Every preset, in display order.
    public static let all: [CaffeineDrink] = [espresso, filterCoffee, blackTea, greenTea, cola, energyDrink, matcha]

    /// The quick-add buttons shown until the user picks their own.
    public static let defaultQuickAddIDs: [String] = [espresso.id, filterCoffee.id, blackTea.id, energyDrink.id]

    public static var defaultQuickAdd: [CaffeineDrink] {
        defaultQuickAddIDs.compactMap(preset(id:))
    }

    /// The preset with `id`; nil for unknown ids (e.g. a preset removed in a later version).
    public static func preset(id: String) -> CaffeineDrink? {
        all.first { $0.id == id }
    }
}
