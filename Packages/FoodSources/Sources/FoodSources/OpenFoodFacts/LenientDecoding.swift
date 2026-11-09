import Foundation

/// Number parsing for Open Food Facts JSON, which sends the same field as a JSON number in one product and as a
/// string in the next ("12.5", "12,5", "< 0.5", "12 g", ""). Nothing here throws or traps: anything unusable is `nil`.
enum LenientNumber {
    /// Leading number of `text`, accepting a decimal comma and a leading `<`, `>`, `~` or `≈` (OFF's "traces"
    /// notation). `nil` for empty, non-numeric or non-finite input.
    static func parse(_ text: String) -> Double? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = rest.first, "<>~≈≤≥".contains(first) || first.isWhitespace {
            rest = rest.dropFirst()
        }
        var digits = ""
        var seenSeparator = false
        for (index, char) in rest.enumerated() {
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

    func lenientStrings(_ key: Key) -> [String] {
        guard let items = try? decodeIfPresent([LenientString].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }
}
