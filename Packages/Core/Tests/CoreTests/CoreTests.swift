import Testing
@testable import Core

@Suite struct CoreTests {
    @Test func moduleLoads() {
        #expect(Core.moduleName == "Core")
    }
}
