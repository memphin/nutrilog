import Testing
@testable import FoodSources

@Suite struct FoodSourcesTests {
    @Test func moduleLoads() {
        #expect(FoodSources.moduleName == "FoodSources")
    }
}
