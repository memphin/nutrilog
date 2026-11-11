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

    /// Every normalized key `raw` can stand for, most likely first; empty when it isn't a valid retail code.
    ///
    /// Usually one key. An 8-digit code can read both as EAN-8 and as UPC-E (expanded to EAN-13), so lookups try
    /// each in order: the hinted reading, then the unhinted one, then UPC-E. An explicit EAN-8 hint is trusted as
    /// is: EAN-8 and UPC-E are separate code spaces that can share the same 8 digits.
    public static func candidates(_ raw: String, symbology: Symbology = .unknown) -> [String] {
        let hints: [Symbology] = symbology == .ean8 ? [.ean8] : [symbology, .unknown, .upcE]
        var result: [String] = []
        for hint in hints {
            if let code = normalize(raw, symbology: hint), !result.contains(code) {
                result.append(code)
            }
        }
        return result
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
        guard digits.count == 8, let payload = upcAPayload(numberSystem: digits[0], data: Array(digits[1 ... 6])) else {
            return nil
        }
        return payload + String(digits[7])
    }

    /// Normalized keys for a code read by a scanner that reported `symbology`, most likely first.
    ///
    /// The same as ``candidates(_:symbology:)``, except for a payload the scanner reported as UPC-E with 6 or 7
    /// digits instead of the full 8 (number system + 6 data digits + check digit); see ``upcEForms(_:)`` for how
    /// those are read. Only for scanner detections, where the symbology is known: typed codes and other symbologies
    /// keep the strict lengths of ``normalize(_:symbology:)``.
    public static func scannedCandidates(_ raw: String, symbology: Symbology) -> [String] {
        let digits = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard symbology == .upcE, digits.count == 6 || digits.count == 7 else {
            return candidates(raw, symbology: symbology)
        }
        var result: [String] = []
        for form in upcEForms(digits) {
            if let code = normalize(form, symbology: .upcE), !result.contains(code) {
                result.append(code)
            }
        }
        return result
    }

    /// The full 8-digit UPC-E codes (number system + 6 data digits + check digit) that a UPC-E payload of 6, 7 or 8
    /// digits can stand for, most likely first; empty when it can't be a UPC-E. Every returned code expands to a
    /// UPC-A with a valid check digit (an 8-digit payload is returned as is and validated by ``normalize``).
    ///
    /// - 8 digits: as is.
    /// - 7 digits: two readings, each checked by expanding to UPC-A.
    ///   1. 6 data digits + check digit, number system 0 implied: valid only when the check digit matches the
    ///      expansion of "0" + the 6 data digits.
    ///   2. Number system + 6 data digits, check digit omitted: possible only when the first digit is 0 or 1; the
    ///      check digit is computed from the expansion.
    ///   When both are possible, reading 1 comes first (its check digit was verified; reading 2 has nothing to
    ///   verify) and reading 2 second, so a lookup tries both. Random digits pass reading 1's check 1 time in 10.
    /// - 6 digits: data only, number system 0; the check digit is computed from the expansion.
    public static func upcEForms(_ raw: String) -> [String] {
        guard raw.allSatisfy(\.isASCIIDigit) else { return [] }
        let digits = raw.compactMap(\.wholeNumberValue)
        switch digits.count {
        case 8:
            return [raw]
        case 7:
            var forms: [String] = []
            // 1. Data + check digit, number system 0.
            if let form = completedUPCE(numberSystem: 0, data: Array(digits[0 ... 5])),
               form.last?.wholeNumberValue == digits[6] {
                forms.append(form)
            }
            // 2. Number system + data, no check digit.
            if let form = completedUPCE(numberSystem: digits[0], data: Array(digits[1 ... 6])), !forms.contains(form) {
                forms.append(form)
            }
            return forms
        case 6:
            return completedUPCE(numberSystem: 0, data: digits).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// The 8-digit UPC-E for a number system and 6 data digits, with the check digit of its UPC-A expansion.
    private static func completedUPCE(numberSystem: Int, data: [Int]) -> String? {
        guard let payload = upcAPayload(numberSystem: numberSystem, data: data),
              let check = checkDigit(forPayload: payload) else { return nil }
        return ([numberSystem] + data + [check]).map(String.init).joined()
    }

    /// The first 11 digits of the UPC-A a UPC-E expands to (everything but the check digit, which UPC-E shares
    /// with its UPC-A); `nil` unless the number system is 0 or 1 and there are 6 data digits.
    private static func upcAPayload(numberSystem: Int, data d: [Int]) -> String? {
        guard numberSystem == 0 || numberSystem == 1, d.count == 6 else { return nil }
        let body: [Int] = switch d[5] {
        case 0, 1, 2: [d[0], d[1], d[5], 0, 0, 0, 0, d[2], d[3], d[4]]
        case 3: [d[0], d[1], d[2], 0, 0, 0, 0, 0, d[3], d[4]]
        case 4: [d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4]]
        default: [d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, d[5]]
        }
        return ([numberSystem] + body).map(String.init).joined()
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        ("0" ... "9").contains(self)
    }
}
