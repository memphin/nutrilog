import Foundation

/// Display casing for names that sources send in ALL CAPS (USDA Branded: "CHOCOLATE HAZELNUT SPREAD",
/// brand owner "FERRERO U.S.A., INCORPORATED"; some OFF products too).
public enum FoodNameCasing {
    /// Words kept lowercase inside a title ("Milk with Cocoa", "Bread and Butter").
    static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "by", "de", "for", "from", "in", "of", "on", "or", "the", "to", "with",
    ]

    /// Abbreviations kept in capitals.
    static let acronyms: Set<String> = ["BBQ", "UHT", "USA", "UK", "EU", "DHA", "MCT", "XL", "XXL", "II", "III", "IV"]

    /// `text` in title case when it is ALL CAPS (at least two letters, none lowercase); otherwise `text` unchanged,
    /// so names typed in mixed case ("McVitie's", "iPhone bar", "Apples, raw") are left alone.
    ///
    /// Each word is lowercased and its first letter capitalized; minor words after the first stay lowercase, known
    /// abbreviations, words of up to three letters without a vowel ("KFC", "DM") and words with digits ("2GO",
    /// "100G") are kept. A letter after an apostrophe stays lowercase ("KELLOGG'S" → "Kellogg's") unless the
    /// apostrophe follows a single letter ("O'REILLY'S" → "O'Reilly's", "D'ARBO" → "D'Arbo"); one after "-", "/",
    /// "(" or "&" starts a new part, and dotted initials ("U.S.A.") are kept.
    public static func titleCasedIfAllCaps(_ text: String) -> String {
        guard isAllCaps(text) else { return text }
        var result = ""
        var word = ""
        var wordIndex = 0
        func flush() {
            guard !word.isEmpty else { return }
            result += casedWord(word, isFirst: wordIndex == 0)
            wordIndex += 1
            word = ""
        }
        for char in text {
            if char.isWhitespace || char == "," {
                flush()
                result.append(char)
            } else {
                word.append(char)
            }
        }
        flush()
        return result
    }

    /// True when `text` has at least two letters and none of them lowercase.
    public static func isAllCaps(_ text: String) -> Bool {
        var letters = 0
        for char in text where char.isLetter {
            if char.isLowercase {
                return false
            }
            if char.isUppercase {
                letters += 1
            }
        }
        return letters >= 2
    }

    /// One whitespace-separated word, which may still contain "-", "/", "(", "." or "'".
    private static func casedWord(_ word: String, isFirst: Bool) -> String {
        let bare = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if acronyms.contains(bare) || bare.contains(where: \.isNumber) || isDotted(bare) || isVowelless(bare) {
            return word
        }
        if !isFirst, minorWords.contains(bare.lowercased()), bare.count == word.count {
            return word.lowercased()
        }
        var result = ""
        var startOfPart = true
        var lettersInPart = 0
        for char in word {
            if char.isLetter {
                result += startOfPart ? char.uppercased() : char.lowercased()
                startOfPart = false
                lettersInPart += 1
            } else {
                result.append(char)
                if char == "-" || char == "/" || char == "(" || char == "&" {
                    startOfPart = true
                    lettersInPart = 0
                } else if char == "'" || char == "\u{2019}" {
                    // O'Reilly, D'Arbo: a single letter before the apostrophe is an elided word.
                    startOfPart = lettersInPart == 1
                    lettersInPart = 0
                }
            }
        }
        return result
    }

    /// Two or three letters and no vowel (Y counts as one): an abbreviation like "KFC" or "DM".
    private static func isVowelless(_ word: String) -> Bool {
        let folded = word.folding(options: .diacriticInsensitive, locale: nil).uppercased()
        return (2 ... 3).contains(folded.count) && folded.allSatisfy(\.isLetter)
            && !folded.contains { "AEIOUY".contains($0) }
    }

    /// Single letters separated by dots, like "U.S.A" or "N.V".
    private static func isDotted(_ word: String) -> Bool {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { $0.count <= 1 }
    }
}

public extension FoodDraft {
    /// The draft with an ALL CAPS name and brand title-cased for display and storage
    /// (``FoodNameCasing/titleCasedIfAllCaps(_:)``); other fields unchanged.
    var displayCased: FoodDraft {
        var draft = self
        draft.name = name.map(FoodNameCasing.titleCasedIfAllCaps)
        draft.nameLocal = nameLocal.map(FoodNameCasing.titleCasedIfAllCaps)
        draft.brand = brand.map(FoodNameCasing.titleCasedIfAllCaps)
        return draft
    }
}
