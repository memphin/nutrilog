import Foundation

/// Number parsing for food-source JSON. Open Food Facts sends the same field as a JSON number in one product and as a
/// string in the next ("12.5", "12,5", "< 0.5", "12 g", ""). Nothing here throws or traps: anything unusable is `nil`.
enum LenientNumber {
    /// The number in `text`, accepting a decimal comma, exponents ("4e-05"), thousands separators ("1.234,5",
    /// "1,234.5"), a leading `<`, `>`, `~` or `≈` (OFF's "traces" notation) and a trailing unit ("12 g").
    /// `nil` for empty, non-numeric or non-finite input.
    static func parse(_ text: String) -> Double? {
        var token = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = token.first, "<>~≈≤≥".contains(first) || first.isWhitespace {
            token = token.dropFirst()
        }
        if !token.isEmpty, token.allSatisfy({ "0123456789.,-+eE".contains($0) }),
           let value = Double(normalizingSeparators(token))
        {
            return value.isFinite ? value : nil
        }
        return leadingNumber(token)
    }

    /// One decimal separator, as a dot. With both "," and ".", the last one is the decimal separator and the other
    /// separates thousands; a lone "," is a decimal comma.
    private static func normalizingSeparators(_ token: Substring) -> String {
        guard let lastComma = token.lastIndex(of: ",") else { return String(token) }
        guard let lastDot = token.lastIndex(of: ".") else {
            return token.replacingOccurrences(of: ",", with: ".")
        }
        if lastComma > lastDot {
            return token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        return token.replacingOccurrences(of: ",", with: "")
    }

    /// Leading number of `text` ("12 g" → 12), with "." or "," as the decimal separator.
    private static func leadingNumber(_ text: Substring) -> Double? {
        var digits = ""
        var seenSeparator = false
        for (index, char) in text.enumerated() {
            if ("0" ... "9").contains(char) {
                digits.append(char)
            } else if char == "." || char == ",", !seenSeparator {
                seenSeparator = true
                digits.append(".")
            } else if char == "-", index == 0 {
                digits.append(char)
            } else {
                break
            }
        }
        if digits.hasSuffix(".") {
            digits.removeLast()
        }
        guard let value = Double(digits), value.isFinite else { return nil }
        return value
    }
}

/// A JSON value read as a number when possible: number, numeric string, or `nil` for anything else
/// (null, bool, object, array, non-numeric string). Decoding never fails.
struct LenientDouble: Decodable {
    let value: Double?

    init(from decoder: any Decoder) {
        guard let container = try? decoder.singleValueContainer(), !container.decodeNil() else {
            value = nil
            return
        }
        if let number = try? container.decode(Double.self) {
            value = number.isFinite ? number : nil
        } else if let text = try? container.decode(String.self) {
            value = LenientNumber.parse(text)
        } else {
            value = nil
        }
    }
}

/// A JSON value read as text: string, or a number rendered as text (OFF sometimes sends `code` as a number).
/// Decoding never fails; whitespace-only strings become `nil`.
struct LenientString: Decodable {
    let value: String?

    init(from decoder: any Decoder) {
        guard let container = try? decoder.singleValueContainer(), !container.decodeNil() else {
            value = nil
            return
        }
        if let text = try? container.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? nil : trimmed
        } else if let integer = try? container.decode(Int64.self) {
            value = String(integer)
        } else if let number = try? container.decode(Double.self), number.isFinite {
            value = String(number)
        } else {
            value = nil
        }
    }
}

/// Coding key for objects with arbitrary keys (`nutriments`).
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key) -> Double? {
        (try? decodeIfPresent(LenientDouble.self, forKey: key))?.value
    }

    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(LenientString.self, forKey: key))?.value
    }
}
