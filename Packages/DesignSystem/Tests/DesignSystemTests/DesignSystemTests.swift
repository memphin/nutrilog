import Testing
@testable import DesignSystem

struct DesignSystemTests {
    @Test func `module loads`() {
        #expect(DesignSystem.moduleName == "DesignSystem")
    }
}
