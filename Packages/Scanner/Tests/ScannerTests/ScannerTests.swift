import AVFoundation
import Core
import Foundation
import Testing
import Vision
@testable import Scanner

struct ScanDebouncerTests {
    /// Feeds `(code, seconds after start)` detections and returns which were accepted.
    private func run(_ detections: [(String, TimeInterval)], with debouncer: ScanDebouncer = ScanDebouncer()) -> [Bool] {
        var debouncer = debouncer
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        return detections.map { debouncer.accept($0.0, at: start.addingTimeInterval($0.1)) }
    }

    @Test func `first detection is accepted`() {
        #expect(run([("3850104003455", 0)]) == [true])
    }

    @Test func `same code within 2 s is ignored`() {
        #expect(run([("3850104003455", 0), ("3850104003455", 0.5), ("3850104003455", 1.999)]) == [true, false, false])
    }

    @Test func `same code after 2 s is accepted again`() {
        #expect(run([("3850104003455", 0), ("3850104003455", 2)]) == [true, true])
    }

    @Test func `ignored repeats do not extend the window`() {
        #expect(run([("A", 0), ("A", 1.5), ("A", 2.1)]) == [true, false, true])
    }

    @Test func `different code is accepted immediately and each code keeps its own window`() {
        #expect(run([("A", 0), ("B", 0.1), ("A", 0.2), ("B", 0.3), ("A", 2.05)]) == [true, true, false, false, true])
    }

    @Test func `reset forgets codes`() {
        var debouncer = ScanDebouncer()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        _ = debouncer.accept("A", at: start)
        debouncer.reset()
        let accepted = debouncer.accept("A", at: start.addingTimeInterval(0.1))
        #expect(accepted)
    }

    @Test func `custom interval`() {
        #expect(run([("A", 0), ("A", 0.4), ("A", 0.5)], with: ScanDebouncer(interval: 0.5)) == [true, false, true])
    }
}

struct SymbologyMappingTests {
    @Test(arguments: [
        (VNBarcodeSymbology.ean13, "3850104003455", Barcode.Symbology.ean13),
        (.ean13, "036000291452", .upcA), // Vision reports UPC-A as EAN-13
        (.ean13, "0036000291452", .ean13),
        (.ean8, "96385074", .ean8),
        (.upce, "04252614", .upcE),
        (.code128, "ABC-123", .unknown),
        (.qr, "https://example.com", .unknown),
    ])
    func `maps Vision symbology to Core`(symbology: VNBarcodeSymbology, payload: String, expected: Barcode.Symbology) {
        #expect(ScannerSymbology.coreSymbology(for: symbology, payload: payload) == expected)
    }

    @Test func `recognizes the FR-10 symbologies`() {
        #expect(Set(ScannerSymbology.recognized) == [.ean13, .ean8, .upce, .code128])
    }

    @Test func `scanned barcode carries the normalized key`() {
        let upcA = ScannerSymbology.barcode(symbology: .ean13, payload: "036000291452")
        #expect(upcA.symbology == .upcA)
        #expect(upcA.normalized == "0036000291452")

        // "04252614" is a valid UPC-E; the symbology hint makes it expand rather than read as EAN-8.
        let upcE = ScannerSymbology.barcode(symbology: .upce, payload: "04252614")
        #expect(upcE.normalized == "0042100005264")

        let code128 = ScannerSymbology.barcode(symbology: .code128, payload: "LOT-42")
        #expect(code128.symbology == .unknown)
        #expect(code128.normalized == nil)
        #expect(code128.payload == "LOT-42")
    }
}

struct ManualBarcodeValidationTests {
    @Test(arguments: [
        ("3850104003455", "3850104003455", Barcode.Symbology.ean13),
        (" 3850-1040-03455 ", "3850104003455", .ean13), // spaces and dashes tolerated
        ("036000291452", "0036000291452", .upcA),
        ("00036000291452", "0036000291452", .unknown), // GTIN-14
        ("96385074", "96385074", .ean8), // only the EAN-8 reading is valid
        ("04252614", "0042100005264", .upcE), // only the UPC-E reading is valid
        ("09999992", "09999992", .unknown), // valid both ways: don't guess
    ])
    func `accepts valid codes`(input: String, normalized: String, symbology: Barcode.Symbology) throws {
        let barcode = try #require(ManualBarcodeValidation(input).barcode)
        #expect(barcode.normalized == normalized)
        #expect(barcode.symbology == symbology)
        #expect(ManualBarcodeValidation(input).message == nil)
    }

    @Test(arguments: [
        ("3850104003456", ManualBarcodeValidation.invalidChecksum),
        ("036000291453", .invalidChecksum),
        ("96385075", .invalidChecksum),
        ("10036000291452", .invalidChecksum), // GTIN-14 with packaging indicator ≠ 0 isn't a retail unit
        ("12345", .invalidLength),
        ("123456789", .invalidLength),
        ("385010400345A", .invalidCharacters),
        ("", .empty),
        ("  ", .empty),
    ])
    func `rejects invalid input`(input: String, expected: ManualBarcodeValidation) {
        let result = ManualBarcodeValidation(input)
        #expect(result == expected)
        #expect(result.barcode == nil)
        #expect((result.message == nil) == (expected == .empty))
    }
}

struct CandidateKeyTests {
    @Test func `typed ambiguous 8-digit code is unknown and carries both keys`() throws {
        let barcode = try #require(ManualBarcodeValidation("09999992").barcode)
        #expect(barcode.symbology == .unknown)
        #expect(barcode.candidates == ["09999992", "0099999000092"])
    }

    @Test(arguments: ["09999992", "01234565", "04252614", "96385074"])
    func `symbology is guessed only when exactly one reading is valid`(code: String) throws {
        let isEAN8 = Barcode.hasValidCheckDigit(code)
        let isUPCE = Barcode.expandUPCE(code).map(Barcode.hasValidCheckDigit) ?? false
        let barcode = try #require(ManualBarcodeValidation(code).barcode)
        let expected: Barcode.Symbology = isEAN8 && isUPCE ? .unknown : (isEAN8 ? .ean8 : .upcE)
        #expect(barcode.symbology == expected)
        #expect(barcode.candidates.count == (isEAN8 && isUPCE ? 2 : 1))
    }

    @Test func `scanned UPC-E puts the UPC-E key first and keeps the EAN-8 reading as fallback`() {
        let barcode = ScannerSymbology.barcode(symbology: .upce, payload: "09999992")
        #expect(barcode.symbology == .upcE)
        #expect(barcode.candidates == ["0099999000092", "09999992"])
        #expect(barcode.normalized == "0099999000092")
    }

    @Test func `scanned EAN-8 is trusted as is`() {
        let barcode = ScannerSymbology.barcode(symbology: .ean8, payload: "09999992")
        #expect(barcode.candidates == ["09999992"])
    }

    @Test func `a 13-digit code has a single key`() {
        #expect(ScannerSymbology.barcode(symbology: .ean13, payload: "3850104003455").candidates == ["3850104003455"])
    }

    @Test func `invalid code has no keys`() {
        let barcode = ScannerSymbology.barcode(symbology: .code128, payload: "LOT-42")
        #expect(barcode.candidates.isEmpty)
        #expect(barcode.normalized == nil)
    }
}

struct ScannerAvailabilityTests {
    @Test(arguments: [
        (AVAuthorizationStatus.notDetermined, true, false, ScannerAvailability.needsPermission),
        (.authorized, true, true, .ready),
        (.authorized, true, false, .unavailable),
        (.denied, true, false, .denied),
        (.restricted, true, false, .restricted),
        (.authorized, false, false, .unsupported),
        (.denied, false, false, .unsupported),
    ])
    func `decides from permission, support and availability`(
        status: AVAuthorizationStatus,
        isSupported: Bool,
        isAvailable: Bool,
        expected: ScannerAvailability,
    ) {
        let availability = ScannerAvailability(authorization: status, isSupported: isSupported, isAvailable: isAvailable)
        #expect(availability == expected)
    }
}

struct ScannerActivityTests {
    @Test func `scans only when ready, not paused, no manual entry and active`() {
        #expect(ScannerActivity.isScanning(availability: .ready, isPaused: false, isShowingManualEntry: false, isAppActive: true))
        #expect(!ScannerActivity.isScanning(availability: .ready, isPaused: true, isShowingManualEntry: false, isAppActive: true))
        #expect(!ScannerActivity.isScanning(availability: .ready, isPaused: false, isShowingManualEntry: true, isAppActive: true))
        #expect(!ScannerActivity.isScanning(availability: .ready, isPaused: false, isShowingManualEntry: false, isAppActive: false))
        #expect(!ScannerActivity.isScanning(availability: .denied, isPaused: false, isShowingManualEntry: false, isAppActive: true))
        #expect(!ScannerActivity.isScanning(availability: nil, isPaused: false, isShowingManualEntry: false, isAppActive: true))
    }
}
