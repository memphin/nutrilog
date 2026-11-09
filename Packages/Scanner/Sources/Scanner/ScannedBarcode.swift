import Core
import Vision

/// A barcode read by the camera or typed by hand, as delivered to the scanner's callback.
public struct ScannedBarcode: Equatable, Sendable {
    /// The code exactly as decoded (or the digits typed).
    public let payload: String
    /// Symbology mapped to Core's model. Code-128 has no Core case and is reported as `.unknown`.
    public let symbology: Barcode.Symbology
    /// Every normalized key the payload can stand for, most likely first. Usually one; an 8-digit code without an
    /// EAN-8 hint can read both as EAN-8 and as UPC-E (expanded to EAN-13), so lookups should try each in order.
    /// The order matches `Persistence.FoodRepository.food(barcode:symbology:)`: the hinted reading, then the
    /// unhinted one, then UPC-E. Empty when the payload isn't a valid retail code, e.g. a Code-128 lot number.
    public let candidates: [String]

    /// The most likely normalized key (EAN-13 / EAN-8), or `nil` when the payload isn't a valid retail code.
    public var normalized: String? {
        candidates.first
    }

    public init(payload: String, symbology: Barcode.Symbology) {
        self.payload = payload
        self.symbology = symbology
        // An explicit EAN-8 is trusted as is: EAN-8 and UPC-E are separate code spaces sharing 8-digit strings.
        let hints: [Barcode.Symbology] = symbology == .ean8 ? [.ean8] : [symbology, .unknown, .upcE]
        var candidates: [String] = []
        for hint in hints {
            if let code = Barcode.normalize(payload, symbology: hint), !candidates.contains(code) {
                candidates.append(code)
            }
        }
        self.candidates = candidates
    }
}

/// The symbologies the scanner recognizes (FR-10) and their mapping to `Core.Barcode.Symbology`.
public enum ScannerSymbology {
    /// Passed to VisionKit. UPC-A has no Vision symbology of its own: Vision decodes it as EAN-13.
    public static let recognized: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128]

    /// Maps a Vision symbology to Core's. The payload length tells UPC-A apart, which Vision reports as EAN-13
    /// with 12 digits. (A 13-digit "0…" EAN-13 is the same product in EAN-13 form, so it stays `.ean13`.)
    public static func coreSymbology(for symbology: VNBarcodeSymbology, payload: String) -> Barcode.Symbology {
        switch symbology {
        case .ean13:
            payload.count == 12 ? .upcA : .ean13
        case .ean8:
            .ean8
        case .upce:
            .upcE
        default:
            .unknown // Code-128 and anything else
        }
    }

    /// Builds the callback value from a Vision observation's symbology and payload.
    public static func barcode(symbology: VNBarcodeSymbology, payload: String) -> ScannedBarcode {
        ScannedBarcode(payload: payload, symbology: coreSymbology(for: symbology, payload: payload))
    }
}
