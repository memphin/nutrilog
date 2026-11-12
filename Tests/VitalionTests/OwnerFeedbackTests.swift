import Core
import Foundation
import HealthKitClient
import Persistence
import Testing
@testable import Vitalion

// Owner feedback after the first device test: 7-day sparklines and a Total energy tile on Today; scanning and
// removing barcodes in the food editor.

// MARK: - Sparklines

struct SparklineTests {
    let today = LocalDay("2026-11-09")!

    func days(_ values: [Int: Double]) -> [LocalDay: Double] {
        Dictionary(uniqueKeysWithValues: values.map { (today.adding(days: -$0.key), $0.value) })
    }

    @Test func `uses the seven days ending today, oldest first, and leaves gaps`() {
        // 7 days ago is outside the window; 2 and 4 days ago have no value.
        let sparkline = Sparkline(days([7: 999, 6: 1, 5: 2, 3: 4, 1: 6, 0: 7]), today: today, mark: .bar)
        #expect(sparkline.points.map(\.index) == [0, 1, 3, 5, 6])
        #expect(sparkline.points.map(\.value) == [1, 2, 4, 6, 7])
        #expect(sparkline.points.first?.day == today.adding(days: -6))
        #expect(sparkline.points.last?.day == today)
        #expect(sparkline.isDrawable)
        #expect(sparkline.direction == .up)
        #expect(sparkline.accessibilitySummary == "up over 7 days")
    }

    @Test func `no data or a single day draws nothing and says nothing`() {
        let empty = Sparkline([:], today: today, mark: .line)
        #expect(empty.points.isEmpty)
        #expect(!empty.isDrawable)
        #expect(empty.direction == nil)
        #expect(empty.accessibilitySummary == nil)
        let single = Sparkline(days([0: 80]), today: today, mark: .line)
        #expect(!single.isDrawable)
        #expect(single.accessibilitySummary == nil)
        // A future day is not part of the window.
        #expect(Sparkline([today.next: 1, today: 2], today: today, mark: .bar).points.count == 1)
    }

    @Test func `direction compares the slope with the average`() {
        #expect(Sparkline(days([6: 82.0, 3: 81.5, 0: 81.0]), today: today, mark: .line).direction == .down)
        #expect(Sparkline(days([6: 60, 5: 61, 4: 59, 3: 60, 2: 59, 1: 61, 0: 60]), today: today, mark: .line).direction == .steady)
        #expect(Sparkline(days([2: 0, 1: 0, 0: 0]), today: today, mark: .bar).direction == .steady)
        #expect(Sparkline(days([2: 0, 1: 5, 0: 0]), today: today, mark: .bar).accessibilitySummary == "up over 7 days")
    }

    @Test func `bar trends skip today's unfinished day, line trends include it`() {
        // 8 a.m.: a steady week of steps and 500 so far today.
        let morning = Sparkline(days([6: 8000, 5: 8100, 4: 7900, 3: 8000, 2: 8100, 1: 7900, 0: 500]), today: today, mark: .bar)
        #expect(morning.isDrawable)
        #expect(morning.points.count == 7) // today is still drawn
        #expect(morning.trendPoints.count == 6)
        #expect(morning.direction == .steady)
        #expect(morning.accessibilitySummary == "steady over 7 days")
        // Only yesterday complete: no trend to speak, the chart still shows.
        let short = Sparkline(days([1: 8000, 0: 500]), today: today, mark: .bar)
        #expect(short.isDrawable)
        #expect(short.direction == nil)
        // A level measured today counts.
        let weight = Sparkline(days([2: 81.0, 1: 81.0, 0: 80.0]), today: today, mark: .line)
        #expect(weight.trendPoints.count == 3)
        #expect(weight.direction == .down)
    }

    @Test func `tiles get their series from one data set`() {
        var data = DashboardData(today: today)
        // 40 days, so the weight trend (which follows weigh-ins slowly) has settled into the 0.1 kg/day loss.
        data.metrics = (0 ..< 40).map { (offset: Int) -> DailyMetricsRecord in
            let steps = 1000 * max(10 - offset, 1)
            let active: Double? = offset == 2 ? nil : 400
            let basal: Double? = offset == 3 ? nil : 1600
            let sleep: Int? = offset == 0 ? 450 : nil
            let weight: Double = 80 + Double(offset) * 0.1
            let water: Double? = offset == 1 ? 500 : nil
            let metrics = DailyHealthMetrics(
                day: today.adding(days: -offset), steps: steps, activeKcal: active, basalKcal: basal,
                sleepAsleepMin: sleep, weightKg: weight, restingHR: 55, waterMl: water,
            )
            return DailyMetricsRecord(metrics, fetchedAt: Date())
        }
        let noon = today.date(atHour: 12)
        data.hydrationIntakes = [
            today: [
                FluidIntake(id: "w1", ml: 500, at: noon, kind: .water, source: .water, name: "Water"),
                FluidIntake(id: "d1", ml: 250, at: noon, kind: .other, source: .diary, name: "Cola"),
            ],
            today.adding(days: -5): [
                FluidIntake(id: "w2", ml: 250, at: today.adding(days: -5).date(atHour: 12), kind: .water, source: .water, name: "Water"),
            ],
        ]
        let snapshot = DashboardSnapshot(data)

        let steps = snapshot.sparklines[.steps]
        #expect(steps?.points.count == 7)
        #expect(steps?.mark == .bar)
        #expect(steps?.points.last?.value == 10000)
        #expect(snapshot.sparkline(for: .steps)?.direction == .up)

        // Total energy only on days with both parts.
        let total = snapshot.sparklines[.totalEnergy]
        #expect(total?.points.map(\.index) == [0, 1, 2, 5, 6])
        #expect(total?.points.last?.value == 2000)
        // Each bar is resting with active on top (#66).
        #expect(total?.points.allSatisfy { $0.base == 1600 } == true)
        #expect(steps?.points.allSatisfy { $0.base == nil } == true)

        // Hydration: every drink logged in Vitalion plus other apps' water, days with neither are gaps.
        let water = snapshot.sparklines[.water]
        #expect(water?.points.map(\.index) == [1, 5, 6])
        #expect(water?.points.map(\.value) == [250, 500, 750])

        // Weight is the trend (a line), falling as the weights do.
        #expect(snapshot.sparklines[.weight]?.mark == .line)
        #expect(snapshot.sparkline(for: .weight)?.direction == .down)
        #expect(snapshot.accessibilityTrend(of: .weight, state: .ready) == "down over 7 days")
        #expect(snapshot.accessibilityTrend(of: .weight, state: .needsAccess) == nil)

        // Sleep: one night only, so nothing to draw yet (#72); no HRV or body fat either.
        #expect(snapshot.sparklines[.sleep]?.points.map(\.value) == [450])
        #expect(snapshot.sparkline(for: .sleep) == nil)
        #expect(snapshot.sparkline(for: .hrv) == nil)
        #expect(snapshot.sparkline(for: .bodyFat) == nil)
        #expect(snapshot.sparkline(for: .restingHeartRate)?.direction == .steady)
        #expect(snapshot.sparkline(for: .energy) == nil)
    }
}

// MARK: - Total energy

struct TotalEnergyTests {
    let today = LocalDay("2026-11-09")!

    func snapshot(active: Double?, basal: Double?) -> DashboardSnapshot {
        var data = DashboardData(today: today)
        data.metrics = [DailyMetricsRecord(DailyHealthMetrics(day: today, activeKcal: active, basalKcal: basal), fetchedAt: Date())]
        return DashboardSnapshot(data)
    }

    @Test func `total is active plus resting`() {
        let snapshot = snapshot(active: 420, basal: 1650)
        let burned = snapshot.energyBurned
        #expect(burned?.totalKcal == 2070)
        #expect(burned?.breakdown(.kcal) == "Active \(EnergyUnit.kcal.format(420)) · Resting \(EnergyUnit.kcal.format(1650))")
        #expect(snapshot.state(of: .totalEnergy, access: .requested, isFirstSync: false) == .ready)
        #expect(snapshot
            .accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish) ==
            "Total energy, 2,070 calories, active 420, close to the active goal of 500, resting 1,650")
    }

    @Test func `with one part known it is shown under its own name, never as the total`() {
        let activeOnly = snapshot(active: 420, basal: nil)
        #expect(activeOnly.energyBurned?.totalKcal == nil)
        #expect(activeOnly.energyBurned?.activeKcal == 420)
        #expect(activeOnly.state(of: .totalEnergy, access: .requested, isFirstSync: false) == .ready)
        #expect(activeOnly.energyBurned?.breakdown(.kcal) == "Active \(EnergyUnit.kcal.format(420)) · Resting unknown")
        #expect(activeOnly.accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish)
            == "Total energy, active 420 calories, close to the active goal of 500, resting energy unknown, no total yet")

        let restingOnly = snapshot(active: nil, basal: 1650)
        #expect(restingOnly.energyBurned?.totalKcal == nil)
        #expect(restingOnly.accessibilityLabel(of: .totalEnergy, state: .ready, locale: .dashboardEnglish)
            == "Total energy, active energy unknown, resting 1,650 calories, no total yet")
    }

    @Test func `a partial day hides the total energy sparkline and its spoken trend`() {
        var data = DashboardData(today: today)
        let history = (1 ... 6).map { offset in
            DailyMetricsRecord(DailyHealthMetrics(day: today.adding(days: -offset), activeKcal: 400, basalKcal: 1600), fetchedAt: Date())
        }
        data.metrics = history + [DailyMetricsRecord(DailyHealthMetrics(day: today, activeKcal: 420), fetchedAt: Date())]
        let partial = DashboardSnapshot(data)
        #expect(partial.sparklines[.totalEnergy]?.isDrawable == true) // the series exists…
        #expect(partial.sparkline(for: .totalEnergy) == nil) // …but isn't shown next to a partial value
        #expect(partial.accessibilityTrend(of: .totalEnergy, state: .ready) == nil)

        data.metrics = history + [DailyMetricsRecord(DailyHealthMetrics(day: today, activeKcal: 420, basalKcal: 1600), fetchedAt: Date())]
        let complete = DashboardSnapshot(data)
        #expect(complete.sparkline(for: .totalEnergy) != nil)
        #expect(complete.accessibilityTrend(of: .totalEnergy, state: .ready) == "steady over 7 days")
    }

    @Test func `with neither part the tile has no value`() {
        let none = snapshot(active: nil, basal: nil)
        #expect(none.energyBurned == nil)
        #expect(none.state(of: .totalEnergy, access: .requested, isFirstSync: false) == .noData(HealthKitClient.noDataMessage))
        #expect(none.state(of: .totalEnergy, access: .notRequested, isFirstSync: false) == .needsAccess)
    }

    @Test func `detail rows show the total and its parts`() {
        var data = DashboardData(today: today)
        data.metrics = [
            DailyMetricsRecord(DailyHealthMetrics(day: today, activeKcal: 400, basalKcal: 1600), fetchedAt: Date()),
            DailyMetricsRecord(DailyHealthMetrics(day: today.previous, activeKcal: 300), fetchedAt: Date()),
        ]
        let rows = TileHistory.rows(for: .totalEnergy, data: data)
        #expect(rows[0].value == EnergyUnit.kcal.format(2000))
        #expect(rows[0].detail == "Active \(EnergyUnit.kcal.format(400)) · Resting \(EnergyUnit.kcal.format(1600))")
        #expect(rows[1].value == nil) // only active known: no total
        #expect(rows[1].detail == "Active \(EnergyUnit.kcal.format(300)) · Resting unknown")
        #expect(rows[2].value == nil)
        #expect(rows[2].detail == nil)
    }
}

// MARK: - Food editor barcodes

@MainActor
struct FoodEditorBarcodeTests {
    let env = AppEnvironment.preview()

    var foods: FoodRepository {
        env.foods!
    }

    func filledEditor(_ name: String, editing: FoodDetail? = nil) -> FoodEditorModel {
        let model = FoodEditorModel(energyUnit: .kcal, editing: editing, initialName: name)
        if editing == nil {
            model.energy = "100"
            model.protein = "1"
            model.carbs = "2"
            model.fat = "3"
        }
        return model
    }

    @Test func `a scan inserts the normalized code once`() {
        let model = filledEditor("Cola")
        // UPC-A as the camera reads it: stored as EAN-13.
        #expect(model.insertScanned(candidates: Barcode.candidates("036000291452", symbology: .upcA)) == .added("0036000291452"))
        #expect(model.barcodes == ["0036000291452"])
        // The same product again, typed with spaces or as GTIN-14: not added twice.
        #expect(model.insertScanned(candidates: Barcode.candidates("0036000 291452")) == .duplicate("0036000291452"))
        #expect(model.insertScanned(candidates: Barcode.candidates("00036000291452")) == .duplicate("0036000291452"))
        // A code typed by hand earlier in another form counts too.
        model.barcodes = ["036000291452", ""]
        #expect(model.insertScanned(candidates: Barcode.candidates("0036000291452")) == .duplicate("0036000291452"))
        // A new code fills the empty row instead of adding another.
        #expect(model.insertScanned(candidates: Barcode.candidates("4006381333931", symbology: .ean13)) == .added("4006381333931"))
        #expect(model.barcodes == ["036000291452", "4006381333931"])
        // Not a retail code (e.g. a Code-128 lot number): nothing changes.
        #expect(model.insertScanned(candidates: Barcode.candidates("LOT-42")) == .invalid)
        #expect(model.barcodes.count == 2)
        #expect(model.normalizedBarcodes == ["0036000291452", "4006381333931"])
    }

    @Test func `an 8-digit code is a duplicate in either reading`() {
        let model = filledEditor("Gum")
        #expect(model.insertScanned(candidates: Barcode.candidates("01000009", symbology: .ean8)) == .added("01000009"))
        // The camera reporting UPC-E for the same printed code.
        #expect(model.insertScanned(candidates: Barcode.candidates("01000009", symbology: .upcE)) == .duplicate("01000009"))
        #expect(model.barcodes == ["01000009"])
    }

    @Test func `rows are removed by id and by swipe offsets`() {
        let model = filledEditor("Bread")
        model.barcodes = ["3850104003455", "", "4006381333931"]
        let empty = model.barcodeRows[1].id
        model.removeBarcode(id: empty)
        #expect(model.barcodes == ["3850104003455", "4006381333931"])
        model.removeBarcodes(atOffsets: [0])
        #expect(model.barcodes == ["4006381333931"])
        model.addBarcodeRow()
        #expect(model.barcodes == ["4006381333931", ""])
        #expect(model.canSave) // an empty row isn't an error
        #expect(model.makeDetail()?.barcodes == ["4006381333931"])
    }

    @Test func `a barcode on another food is reported before saving and moved only after consent`() throws {
        let nutella = try foods.save(FoodDetail(
            food: Food(name: "Nutella", per100: Nutrients(kcal: 539, proteinG: 6, carbsG: 57, fatG: 31)),
            barcodes: ["3017620422003"],
        ))
        let model = filledEditor("Hazelnut spread")
        model.insertScanned(candidates: Barcode.candidates("3017620422003", symbology: .ean13))

        let conflicts = try model.barcodeConflicts(in: foods)
        #expect(conflicts == [.init(barcode: "3017620422003", foodID: nutella.food.id, foodName: "Nutella")])
        #expect(FoodEditorModel.moving(conflicts) == ["3017620422003": nutella.food.id])
        #expect(FoodEditorModel.conflictMessage(conflicts) == "This barcode is on 'Nutella' — move it here?")
        model.refreshBarcodeOwners(in: foods)
        #expect(model.owner(of: "3017620422003") == "Nutella")

        // Saving without consent fails as before and changes nothing.
        #expect(throws: PersistenceError.barcodeInUse(barcode: "3017620422003", foodID: nutella.food.id)) {
            try model.save(to: foods)
        }
        #expect(try foods.food(barcode: "3017620422003")?.food.id == nutella.food.id)

        // "Move here".
        let saved = try #require(try model.save(to: foods, movingBarcodes: FoodEditorModel.moving(conflicts)))
        #expect(try foods.food(barcode: "3017620422003")?.food.id == saved.food.id)
        #expect(try foods.detail(id: nutella.food.id)?.barcodes == [])

        // The food's own barcodes are never a conflict when editing it.
        let reopened = FoodEditorModel(energyUnit: .kcal, editing: saved)
        #expect(try reopened.barcodeConflicts(in: foods).isEmpty)
    }

    @Test func `a code stored under its other 8-digit reading on another food is a conflict`() throws {
        let gum = try foods.save(FoodDetail(
            food: Food(name: "Gum", per100: Nutrients(kcal: 200, proteinG: 0, carbsG: 60, fatG: 0)),
            barcodes: ["0010000000009"], // UPC-E, expanded
        ))
        let model = filledEditor("Mint gum")
        model.insertScanned(candidates: Barcode.candidates("01000009", symbology: .ean8))
        let conflicts = try model.barcodeConflicts(in: foods)
        #expect(conflicts == [.init(barcode: "01000009", storedBarcode: "0010000000009", foodID: gum.food.id, foodName: "Gum")])
        model.refreshBarcodeOwners(in: foods)
        #expect(model.owner(of: "01000009") == "Gum")
        let saved = try #require(try model.save(to: foods, movingBarcodes: FoodEditorModel.moving(conflicts)))
        #expect(try foods.detail(id: gum.food.id)?.barcodes == [])
        #expect(try foods.food(barcodes: Barcode.candidates("01000009", symbology: .upcE))?.food.id == saved.food.id)
    }

    @Test func `moving fails if the code went to another food after the warning`() throws {
        let first = try foods.save(FoodDetail(
            food: Food(name: "First", per100: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0)),
            barcodes: ["3850104003455"],
        ))
        let model = filledEditor("Mine")
        model.barcodes = ["3850104003455"]
        let conflicts = try model.barcodeConflicts(in: foods)
        // Meanwhile the code moved to another food.
        try foods.softDelete(id: first.food.id)
        let other = try foods.save(FoodDetail(
            food: Food(name: "Other", per100: Nutrients(kcal: 1, proteinG: 0, carbsG: 0, fatG: 0)),
            barcodes: ["3850104003455"],
        ))
        #expect(throws: PersistenceError.barcodeInUse(barcode: "3850104003455", foodID: other.food.id)) {
            try model.save(to: foods, movingBarcodes: FoodEditorModel.moving(conflicts))
        }
        #expect(try foods.food(barcode: "3850104003455")?.food.id == other.food.id)
    }

    @Test func `deleting a barcode persists and the next scan no longer finds the food`() throws {
        let model = filledEditor("Ajvar")
        model.barcodes = ["3850104003455"] // added by hand
        let saved = try #require(try model.save(to: foods))
        #expect(try foods.food(barcodes: Barcode.candidates("3850104003455", symbology: .ean13))?.food.id == saved.food.id)

        let stored: FoodDetail = try #require(try foods.detail(id: saved.food.id))
        let editor = FoodEditorModel(energyUnit: .kcal, editing: stored)
        #expect(editor.barcodes == ["3850104003455"])
        editor.removeBarcode(id: editor.barcodeRows[0].id)
        let updated = try #require(try editor.save(to: foods))
        #expect(updated.barcodes.isEmpty)
        #expect(try foods.detail(id: saved.food.id)?.barcodes == [])
        // What the scanner does on the next scan of that code.
        #expect(try foods.food(barcodes: Barcode.candidates("3850104003455", symbology: .ean13)) == nil)
        #expect(try foods.food(barcode: "3850104003455") == nil)
    }
}
