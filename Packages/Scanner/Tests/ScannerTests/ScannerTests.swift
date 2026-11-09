import Testing
@testable import Scanner

@Suite struct ScannerTests {
    @Test func moduleLoads() {
        #expect(Scanner.moduleName == "Scanner")
    }
}
