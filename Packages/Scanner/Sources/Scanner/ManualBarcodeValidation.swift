import Core

/// Validation of a barcode typed by hand (FR-14). Check-digit logic lives in `Core.Barcode`.
public enum ManualBarcodeValidation: Equatable, Sendable {
    case valid(ScannedBarcode)
    case empty
    /// Something other than digits, spaces or dashes.
    case invalidCharacters
    /// Not 8, 12, 13 or 14 digits.
    case invalidLength
    /// Right length, wrong check digit.
    case invalidChecksum

    public static let acceptedLengths: Set<Int> = [8, 12, 13, 14]

    public init(_ input: String) {
        let digits = input.filter { !$0.isWhitespace && $0 != "-" }
        guard !digits.isEmpty else {
            self = .empty
            return
        }
        guard digits.allSatisfy({ ("0" ... "9").contains($0) }) else {
            self = .invalidCharacters
            return
        }
        guard Self.acceptedLengths.contains(digits.count) else {
            self = .invalidLength
            return
        }
        let barcode = ScannedBarcode(payload: digits, symbology: Self.symbology(forDigits: digits))
        self = barcode.normalized == nil ? .invalidChecksum : .valid(barcode)
    }

    public var barcode: ScannedBarcode? {
        if case let .valid(barcode) = self {
            barcode
        } else {
            nil
        }
    }

    /// Short user-facing message; `nil` when valid or empty.
    public var message: String? {
        switch self {
        case .valid, .empty: nil
        case .invalidCharacters: "Use digits only."
        case .invalidLength: "A barcode has 8, 12, 13 or 14 digits."
        case .invalidChecksum: "The check digit doesn't match. Please re-check the number."
        }
    }

    /// Typed codes carry no symbology, so infer it from the length. An 8-digit code is EAN-8 when its
    /// check digit says so, otherwise UPC-E (the same rule `Barcode.normalize` applies).
    static func symbology(forDigits digits: String) -> Barcode.Symbology {
        switch digits.count {
        case 13: .ean13
        case 12: .upcA
        case 8: Barcode.hasValidCheckDigit(digits) ? .ean8 : .upcE
        default: .unknown
        }
    }
}
