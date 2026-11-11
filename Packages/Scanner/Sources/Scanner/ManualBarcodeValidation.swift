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
    /// A GTIN-14 with a valid check digit whose packaging indicator (first digit) is 1–9: the code of an outer
    /// case or tray, not of the retail unit inside, so it isn't looked up.
    case outerPackCode

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
        if barcode.normalized != nil {
            self = .valid(barcode)
        } else if digits.count == 14, digits.first != "0", Barcode.hasValidCheckDigit(digits) {
            self = .outerPackCode
        } else {
            self = .invalidChecksum
        }
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
        case .outerPackCode: "This is an outer-pack code. Type the 13 digits printed on the product itself."
        }
    }

    /// Typed codes carry no symbology, so infer it from the length. An 8-digit code is `.ean8` or `.upcE` only
    /// when exactly one reading has a valid check digit; when both do (common: most UPC-E codes also pass the
    /// EAN-8 check) it stays `.unknown` and `ScannedBarcode.candidates` carries both keys.
    static func symbology(forDigits digits: String) -> Barcode.Symbology {
        switch digits.count {
        case 13: return .ean13
        case 12: return .upcA
        case 8:
            let isEAN8 = Barcode.hasValidCheckDigit(digits)
            let isUPCE = Barcode.expandUPCE(digits).map(Barcode.hasValidCheckDigit) ?? false
            switch (isEAN8, isUPCE) {
            case (true, false): return .ean8
            case (false, true): return .upcE
            default: return .unknown
            }
        default: return .unknown
        }
    }
}
