import Testing
@testable import DesignSystem

@Suite struct DesignSystemTests {
    @Test func moduleLoads() {
        #expect(DesignSystem.moduleName == "DesignSystem")
    }
}
