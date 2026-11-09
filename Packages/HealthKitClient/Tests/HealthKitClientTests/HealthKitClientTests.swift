import Testing
@testable import HealthKitClient

struct HealthKitClientTests {
    @Test func `module loads`() {
        #expect(HealthKitClient.moduleName == "HealthKitClient")
    }
}
