import Testing
@testable import Core

struct CoreTests {
    @Test func `module loads`() {
        #expect(Core.moduleName == "Core")
    }
}
