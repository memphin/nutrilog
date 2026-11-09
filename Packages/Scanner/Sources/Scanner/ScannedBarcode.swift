import Core
import Vision

/// A barcode read by the camera or typed by hand, as delivered to the scanner's callback.
public struct ScannedBarcode: Equatable, Sendable {
    /// The code exactly as decoded (or the digits typed).
    public let payload: String
    /// Symbology mapped to Core's model. Code-128 has no Core case and is reported as `.unknown`.
    public let symbology: Barcode.Symbology
    /// `Barcode.normalize` result (EAN-13 / EAN-8 key), or `nil` when the payload isn't a valid retail code,
    /// e.g. a Code-128 label that doesn't carry a GTIN.
    public let normalized: String?

    public init(payload: String, symbology: Barcode.Symbology) {
        self.payload = payload
        self.symbology = symbology
        normalized = Barcode.normalize(payload, symbology: symbology)
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
