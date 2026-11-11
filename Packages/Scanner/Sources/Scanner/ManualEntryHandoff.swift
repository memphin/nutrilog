/// Hands a typed barcode to the caller only once the manual-entry sheet has finished dismissing.
///
/// Delivering it while the sheet is still on its way out lets the caller present its own sheet (e.g. the product
/// card of a local hit) during that dismissal, which SwiftUI may drop, leaving the camera paused with nothing on
/// screen. The submitted code is held here and delivered from the sheet's `onDismiss`. Pure, so it can be tested
/// without a camera.
public struct ManualEntryHandoff: Equatable, Sendable {
    public private(set) var pending: ScannedBarcode?

    public init() {}

    /// A code is waiting for the sheet to finish dismissing. The camera stays off meanwhile.
    public var isPending: Bool {
        pending != nil
    }

    /// The user submitted a valid code: hold it (the latest submission wins) until ``sheetDidDismiss()``.
    public mutating func submit(_ barcode: ScannedBarcode) {
        pending = barcode
    }

    /// The sheet finished dismissing: the code to deliver now, if one was submitted (nil after Cancel or a swipe
    /// down). Clears it, so it is delivered once.
    public mutating func sheetDidDismiss() -> ScannedBarcode? {
        defer { pending = nil }
        return pending
    }
}
