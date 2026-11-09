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
}
