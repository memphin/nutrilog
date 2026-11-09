import Foundation

/// Barcode normalization (SPEC §9, backlog #2).
///
/// All product codes are stored as EAN-13 where possible so that the same product scanned as UPC-A,
/// UPC-E, EAN-13 or GTIN-14 maps to one key. EAN-8 stays 8 digits (it is a separate code space).
public enum Barcode {
    /// Symbology reported by the scanner. Needed for 8-digit codes: many UPC-E codes are also valid EAN-8s.
    public enum Symbology: Equatable, Sendable {
        case ean13, ean8, upcA, upcE, unknown
    }

    /// Normalized code or `nil` when the input isn't a valid retail barcode.
    ///
    /// - EAN-13 → as is
    /// - UPC-A (12) → "0" + code (EAN-13)
    /// - UPC-E (8, number system 0/1) → expanded to UPC-A → EAN-13. Without a symbology hint an 8-digit code is
    ///   read as EAN-8 first and as UPC-E only when its EAN-8 check digit fails.
    /// - GTIN-14 with leading "0" → last 13 digits
    /// - EAN-8 → as is
    public static func normalize(_ raw: String, symbology: Symbology = .unknown) -> String? {
        let digits = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }

        switch digits.count {
        case 13:
            return hasValidCheckDigit(digits) ? digits : nil
        case 12:
            return hasValidCheckDigit(digits) ? "0" + digits : nil
        case 14:
            guard digits.first == "0", hasValidCheckDigit(digits) else { return nil }
            return String(digits.dropFirst())
        case 8:
            if symbology == .upcE {
                guard let upcA = expandUPCE(digits), hasValidCheckDigit(upcA) else { return nil }
                return "0" + upcA
            }
            if hasValidCheckDigit(digits) {
                return digits
            }
            if let upcA = expandUPCE(digits), hasValidCheckDigit(upcA) {
                return "0" + upcA
            }
            return nil
        default:
            return nil
        }
    }

    /// True when the last digit is the correct GS1 mod-10 check digit.
    public static func hasValidCheckDigit(_ digits: String) -> Bool {
        guard digits.count >= 8, let check = digits.last?.wholeNumberValue else { return false }
        return checkDigit(forPayload: String(digits.dropLast())) == check
    }

    /// GS1 mod-10 check digit for a payload (all digits except the check digit).
    public static func checkDigit(forPayload payload: String) -> Int? {
        var sum = 0
        // Weights alternate 3,1,3,… starting from the rightmost payload digit.
        for (index, char) in payload.reversed().enumerated() {
            guard let value = char.wholeNumberValue else { return nil }
            sum += value * (index.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// Expands an 8-digit UPC-E (number system, 6 digits, check) to 12-digit UPC-A.
    public static func expandUPCE(_ code: String) -> String? {
        let digits = code.compactMap(\.wholeNumberValue)
        guard digits.count == 8, digits[0] == 0 || digits[0] == 1 else { return nil }
        let numberSystem = digits[0]
        let d = Array(digits[1 ... 6])
        let check = digits[7]
        let body: [Int] = switch d[5] {
        case 0, 1, 2: [d[0], d[1], d[5], 0, 0, 0, 0, d[2], d[3], d[4]]
        case 3: [d[0], d[1], d[2], 0, 0, 0, 0, 0, d[3], d[4]]
        case 4: [d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4]]
        default: [d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, d[5]]
        }
        return ([numberSystem] + body + [check]).map(String.init).joined()
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        ("0" ... "9").contains(self)
    }
}
