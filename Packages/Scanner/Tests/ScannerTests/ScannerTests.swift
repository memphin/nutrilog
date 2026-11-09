import Testing
@testable import Scanner

struct ScannerTests {
    @Test func `module loads`() {
        #expect(Scanner.moduleName == "Scanner")
    }
}
