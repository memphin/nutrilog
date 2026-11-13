import Core
import Foundation
import Persistence
import Testing
@testable import Vitalion

/// Barcodes in the food editor: scanning one in, removing rows, and moving a code another food already has.
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
