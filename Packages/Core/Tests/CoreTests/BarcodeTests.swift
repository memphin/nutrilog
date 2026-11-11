import Testing
@testable import Core

struct BarcodeTests {
    @Test(arguments: [
        ("3850104003455", "3850104003455"), // EAN-13 (Croatian prefix 385)
        ("4006381333931", "4006381333931"), // EAN-13
        ("036000291452", "0036000291452"), // UPC-A → EAN-13
        ("00036000291452", "0036000291452"), // GTIN-14 → EAN-13
        ("96385074", "96385074"), // EAN-8
        ("04252614", "0042100005264"), // UPC-E (not a valid EAN-8) → UPC-A → EAN-13
        (" 4006381-333931 ", "4006381333931"), // whitespace and dashes ignored
    ])
    func `normalizes valid codes`(input: String, expected: String) {
        #expect(Barcode.normalize(input) == expected)
    }

    @Test(arguments: [
        "4006381333932", // wrong check digit
        "036000291453", // wrong UPC-A check digit
        "10036000291452", // GTIN-14 with packaging indicator ≠ 0
        "12345", // too short
        "40063813339A1", // letters
        "",
        "96385075", // invalid EAN-8 and not a valid UPC-E
    ])
    func `rejects invalid codes`(input: String) {
        #expect(Barcode.normalize(input) == nil)
    }

    @Test func `symbology hint resolves UPC evs EAN 8`() {
        // "01234565" is valid both as EAN-8 and as UPC-E.
        #expect(Barcode.normalize("01234565") == "01234565")
        #expect(Barcode.normalize("01234565", symbology: .ean8) == "01234565")
        #expect(Barcode.normalize("01234565", symbology: .upcE) == "0012345000065")
        #expect(Barcode.normalize("01234566", symbology: .upcE) == nil)
    }

    @Test func `candidates list every reading most likely first`() {
        // Ambiguous 8 digits: EAN-8 first without a hint, UPC-E first with a UPC-E hint, EAN-8 only with an EAN-8 hint.
        #expect(Barcode.candidates("01234565") == ["01234565", "0012345000065"])
        #expect(Barcode.candidates("01234565", symbology: .upcE) == ["0012345000065", "01234565"])
        #expect(Barcode.candidates("01234565", symbology: .ean8) == ["01234565"])
        #expect(Barcode.candidates("036000291452", symbology: .upcA) == ["0036000291452"])
        #expect(Barcode.candidates("garbage").isEmpty)
    }

    @Test func `check digit`() {
        #expect(Barcode.checkDigit(forPayload: "400638133393") == 1)
        #expect(Barcode.checkDigit(forPayload: "03600029145") == 2)
        #expect(Barcode.checkDigit(forPayload: "12a") == nil)
        #expect(!Barcode.hasValidCheckDigit("1234567"))
    }

    @Test func `upc E expansion rules`() {
        #expect(Barcode.expandUPCE("01234565") == "012345000065") // last digit 5 → manufacturer 12345
        #expect(Barcode.expandUPCE("04252614") == "042100005264") // last digit 0–2
        #expect(Barcode.expandUPCE("01234531") == "012300000451") // last digit 3
        #expect(Barcode.expandUPCE("01234544") == "012340000054") // last digit 4
        #expect(Barcode.expandUPCE("21234565") == nil) // number system must be 0/1
        #expect(Barcode.expandUPCE("0123") == nil)
    }

    // Vectors expanded by hand (UPC-A check digit: weights 3,1,3,… from the rightmost payload digit):
    // - 123456 (last digit 5–9): 0 12345 0000 6 → payload 01234500006, sum 45 → check 5 → UPC-E 01234565.
    // - 425261 (last digit 0–2): 0 42 1 0000 526 → payload 04210000526, sum 46 → check 4 → UPC-E 04252614.
    // - 123453 (last digit 3): 0 123 00000 45 → payload 01230000045, sum 29 → check 1 → UPC-E 01234531.
    // - 123454 (last digit 4): 0 1234 00000 5 → payload 01234000005, sum 37 → check 3 → UPC-E 01234543.
    // - NS 1, 425261: 1 42 1 0000 526 → payload 14210000526, sum 49 → check 1 → UPC-E 14252611.
    // - 042526 (last digit 6): 0 04252 0000 6 → payload 00425200006, sum 49 → check 1 → UPC-E 00425261.
    // - NS 1, 234565: 1 23456 0000 5 → payload 12345600005, sum 54 → check 6 → UPC-E 12345656.
    @Test(arguments: Self.scannedUPCEVectors)
    func `scanned UPC-E of 6, 7 or 8 digits`(payload: String, expected: [String]) {
        #expect(Barcode.scannedCandidates(payload, symbology: .upcE) == expected)
    }

    static let scannedUPCEVectors: [(String, [String])] = [
        // 6 digits: data only, number system 0, check digit computed.
        ("123456", ["0012345000065"]),
        ("425261", ["0042100005264"]),
        ("123453", ["0012300000451"]),
        ("123454", ["0012340000053"]),
        // 7 digits, only "data + check" fits (first digit isn't a number system 0/1).
        ("4252614", ["0042100005264"]),
        // 7 digits, only "number system + data" fits (the last digit isn't the check digit of "0" + first six).
        ("0123456", ["0012345000065"]),
        ("1425261", ["0142100005261"]),
        // 7 digits that fit both readings: the one with a verified check digit first.
        ("1234565", ["0012345000065", "0123456000056"]),
        ("0425261", ["0004252000061", "0042100005264"]),
        // 7 digits that fit neither.
        ("4252615", []),
        // 8 digits: unchanged.
        ("04252614", ["0042100005264"]),
        ("01234565", ["0012345000065", "01234565"]),
        ("01234566", []), // valid neither as UPC-E nor as EAN-8
    ]

    @Test func `upc E forms`() {
        #expect(Barcode.upcEForms("123456") == ["01234565"])
        #expect(Barcode.upcEForms("1234565") == ["01234565", "12345656"])
        #expect(Barcode.upcEForms("0425261") == ["00425261", "04252614"])
        #expect(Barcode.upcEForms("1425261") == ["14252611"])
        #expect(Barcode.upcEForms("04252614") == ["04252614"])
        #expect(Barcode.upcEForms("12345") == [])
        #expect(Barcode.upcEForms("12345A") == [])
        #expect(Barcode.upcEForms("") == [])
        // Every form expands to a UPC-A with a valid check digit.
        for payload in ["123456", "1234565", "0425261", "1425261", "999999", "1999999"] {
            for form in Barcode.upcEForms(payload) {
                #expect(Barcode.expandUPCE(form).map(Barcode.hasValidCheckDigit) == true, "\(payload) → \(form)")
            }
        }
    }

    @Test func `short UPC-E is accepted only from a scanner that reported UPC-E`() {
        // Other symbologies and the plain entry points keep rejecting 6 and 7 digits.
        for payload in ["123456", "1234565", "0123456"] {
            for symbology: Barcode.Symbology in [.unknown, .ean8, .ean13, .upcA] {
                #expect(Barcode.scannedCandidates(payload, symbology: symbology).isEmpty)
            }
            #expect(Barcode.normalize(payload) == nil)
            #expect(Barcode.normalize(payload, symbology: .upcE) == nil)
            #expect(Barcode.candidates(payload, symbology: .upcE).isEmpty)
        }
        // Longer codes go through the usual rules, whatever the symbology.
        #expect(Barcode.scannedCandidates("036000291452", symbology: .upcA) == ["0036000291452"])
        #expect(Barcode.scannedCandidates("01234565", symbology: .ean8) == ["01234565"])
        #expect(Barcode.scannedCandidates("LOT-42", symbology: .upcE).isEmpty)
    }
}
