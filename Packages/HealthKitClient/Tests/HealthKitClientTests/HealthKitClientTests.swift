import Testing
@testable import HealthKitClient

@Suite struct HealthKitClientTests {
    @Test func moduleLoads() {
        #expect(HealthKitClient.moduleName == "HealthKitClient")
    }
}
