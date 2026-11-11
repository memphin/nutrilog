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

struct ScanResumeTests {
    /// A debouncer driven with times in seconds after a fixed start; a class so it can be used inside `#expect`.
    final class Clocked {
        var debouncer: ScanDebouncer
        let start = Date(timeIntervalSinceReferenceDate: 1000)

        init(_ debouncer: ScanDebouncer = ScanDebouncer()) {
            self.debouncer = debouncer
        }

        func accept(_ code: String, at seconds: TimeInterval) -> Bool {
            debouncer.accept(code, at: start.addingTimeInterval(seconds))
        }

        func pause() {
            debouncer.pause()
        }

        func resume(at seconds: TimeInterval) {
            debouncer.resume(at: start.addingTimeInterval(seconds))
        }

        func codeLeftView(_ code: String) {
            debouncer.codeLeftView(code)
        }

        func noteHandled(_ code: String) {
            debouncer.noteHandled(code)
        }

        func reset() {
            debouncer.reset()
        }
    }

    /// "A" is accepted, a result sheet pauses the camera for `pause` seconds, then scanning resumes.
    func resumedAfterHandlingA(pause: TimeInterval = 20) -> Clocked {
        let debouncer = Clocked()
        #expect(debouncer.accept("A", at: 0))
        debouncer.pause()
        debouncer.resume(at: pause)
        return debouncer
    }

    @Test func `the code handled last is suppressed for 3 s after resuming`() {
        let debouncer = resumedAfterHandlingA()
        #expect(!debouncer.accept("A", at: 20))
        #expect(!debouncer.accept("A", at: 22.999))
        #expect(debouncer.accept("A", at: 23))
    }

    @Test func `a different code is accepted immediately after resuming`() {
        let debouncer = resumedAfterHandlingA()
        #expect(debouncer.accept("B", at: 20))
    }

    @Test func `the same code is accepted again once it left the view`() {
        let debouncer = resumedAfterHandlingA()
        #expect(!debouncer.accept("A", at: 20.1)) // still in view
        debouncer.codeLeftView("A")
        #expect(debouncer.accept("A", at: 21)) // brought back
    }

    @Test func `a removal before it was seen again doesn't end the suppression`() {
        // E.g. a removal VisionKit reports for the detection from before the pause.
        let debouncer = resumedAfterHandlingA()
        debouncer.codeLeftView("A")
        #expect(!debouncer.accept("A", at: 20.1))
        debouncer.codeLeftView("B") // another code leaving changes nothing
        #expect(!debouncer.accept("A", at: 20.2))
    }

    @Test func `the suppression holds from the pause until the countdown after resuming`() {
        let debouncer = Clocked()
        #expect(debouncer.accept("A", at: 0))
        debouncer.pause()
        #expect(!debouncer.accept("A", at: 60)) // a late detection before the resume is recorded
        debouncer.resume(at: 61)
        #expect(!debouncer.accept("A", at: 63.9))
        #expect(debouncer.accept("A", at: 64))
    }

    @Test func `seen during the pause and gone after resuming ends the suppression`() {
        let debouncer = Clocked()
        #expect(debouncer.accept("A", at: 0))
        debouncer.pause()
        #expect(!debouncer.accept("A", at: 1))
        debouncer.resume(at: 2)
        debouncer.codeLeftView("A")
        #expect(debouncer.accept("A", at: 2.5))
    }

    @Test func `the repeat interval still applies after a short pause`() {
        // A lookup that ends quickly (e.g. not a product code): the 2 s interval of the accepted detection holds on
        // its own once the resume suppression has been lifted by the code leaving the view.
        let debouncer = resumedAfterHandlingA(pause: 0.5)
        #expect(!debouncer.accept("A", at: 0.6))
        debouncer.codeLeftView("A")
        #expect(!debouncer.accept("A", at: 1))
        #expect(debouncer.accept("A", at: 2))
    }

    @Test func `only the code handled last is suppressed`() {
        let debouncer = Clocked()
        #expect(debouncer.accept("A", at: 0))
        #expect(debouncer.accept("B", at: 1))
        debouncer.pause()
        debouncer.resume(at: 20)
        #expect(debouncer.accept("A", at: 20))
        #expect(!debouncer.accept("B", at: 20))
    }

    @Test func `nothing is suppressed on the first start`() {
        let debouncer = Clocked()
        debouncer.pause()
        debouncer.resume(at: 0)
        #expect(debouncer.accept("A", at: 0))
    }

    @Test func `a typed code is suppressed after resuming too`() {
        let debouncer = Clocked()
        debouncer.pause() // the manual-entry sheet covers the camera
        debouncer.noteHandled("3850104003455")
        debouncer.resume(at: 10)
        #expect(!debouncer.accept("3850104003455", at: 10.5))
        #expect(debouncer.accept("3850104003455", at: 13))
    }

    @Test func `custom suppression and reset`() {
        let debouncer = Clocked(ScanDebouncer(resumeSuppression: 1))
        #expect(debouncer.accept("A", at: 0))
        debouncer.pause()
        debouncer.resume(at: 10)
        #expect(!debouncer.accept("A", at: 10.9))
        #expect(debouncer.accept("A", at: 11))

        debouncer.pause()
        debouncer.resume(at: 20)
        debouncer.reset()
        #expect(debouncer.accept("A", at: 20))
    }
}

struct ManualEntryHandoffTests {
    let barcode = ScannedBarcode(payload: "3850104003455", symbology: .ean13)

    @Test func `a submitted code is held until the sheet has dismissed, then delivered once`() {
        var handoff = ManualEntryHandoff()
        #expect(!handoff.isPending)
        handoff.submit(barcode)
        #expect(handoff.isPending) // keeps the camera off while the sheet goes away
        let delivered = handoff.sheetDidDismiss()
        #expect(delivered == barcode)
        #expect(!handoff.isPending)
        let again = handoff.sheetDidDismiss()
        #expect(again == nil)
    }

    @Test func `cancelling delivers nothing`() {
        var handoff = ManualEntryHandoff()
        let delivered = handoff.sheetDidDismiss()
        #expect(delivered == nil)
        #expect(!handoff.isPending)
    }

    @Test func `the latest submission wins`() {
        var handoff = ManualEntryHandoff()
        handoff.submit(ScannedBarcode(payload: "96385074", symbology: .ean8))
        handoff.submit(barcode)
        let delivered = handoff.sheetDidDismiss()
        #expect(delivered == barcode)
    }

    @Test func `a pending code keeps the camera off`() {
        var handoff = ManualEntryHandoff()
        handoff.submit(barcode)
        // BarcodeScannerView passes `isShowingManualEntry || handoff.isPending`.
        #expect(!ScannerActivity.isScanning(
            availability: .ready, isPaused: false, isShowingManualEntry: handoff.isPending, isAppActive: true,
        ))
    }
}

struct ShortUPCETests {
    @Test(arguments: [
        ("01234565", ["0012345000065", "01234565"]), // 8 digits: as before
        ("1234565", ["0012345000065", "0123456000056"]), // 7: data + check first, then number system + data
        ("0123456", ["0012345000065"]), // 7: number system + data only
        ("4252614", ["0042100005264"]), // 7: data + check only
        ("123456", ["0012345000065"]), // 6: data only
    ])
    func `a scanned UPC-E of 6, 7 or 8 digits resolves`(payload: String, expected: [String]) {
        let barcode = ScannerSymbology.barcode(symbology: .upce, payload: payload)
        #expect(barcode.symbology == .upcE)
        #expect(barcode.payload == payload)
        #expect(barcode.candidates == expected)
    }

    @Test func `short codes of other symbologies are still rejected`() {
        for payload in ["123456", "1234565"] {
            #expect(ScannerSymbology.barcode(symbology: .ean8, payload: payload).candidates.isEmpty)
            #expect(ScannerSymbology.barcode(symbology: .ean13, payload: payload).candidates.isEmpty)
            #expect(ScannerSymbology.barcode(symbology: .code128, payload: payload).candidates.isEmpty)
        }
    }

    @Test func `typed 6 or 7 digits are still rejected`() {
        #expect(ManualBarcodeValidation("123456") == .invalidLength)
        #expect(ManualBarcodeValidation("1234565") == .invalidLength)
        #expect(ManualBarcodeValidation.symbology(forDigits: "1234565") == .unknown)
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
        ("10036000291452", .invalidChecksum), // packaging indicator 1, but the check digit is wrong too
        ("10012345678902", .outerPackCode), // valid GTIN-14 of an outer case: not a retail unit
        ("2001-2345-678909", .outerPackCode),
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

    @Test func `an outer-pack code is not blamed on the check digit`() {
        let result = ManualBarcodeValidation("10012345678902")
        #expect(result == .outerPackCode)
        #expect(result.message == "This is an outer-pack code. Type the 13 digits printed on the product itself.")
        #expect(result.message != ManualBarcodeValidation.invalidChecksum.message)
        // The same digits with a leading 0 are a valid retail GTIN-14, and a wrong check digit stays a checksum error.
        #expect(ManualBarcodeValidation("00012345678905").barcode != nil)
        #expect(ManualBarcodeValidation("10012345678903") == .invalidChecksum)
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
