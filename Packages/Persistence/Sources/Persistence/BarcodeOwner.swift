/// Another food carrying a barcode (``FoodRepository/activeOwners(of:excluding:)``).
public struct BarcodeOwner: Equatable, Sendable {
    /// The code as asked about (the editor's row).
    public var barcode: String
    /// The key the other food stores it under: `barcode` itself, or another reading of the same digits.
    public var storedBarcode: String
    public var food: Food

    public init(barcode: String, storedBarcode: String, food: Food) {
        self.barcode = barcode
        self.storedBarcode = storedBarcode
        self.food = food
    }
}
