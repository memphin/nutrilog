import Testing
@testable import FoodSources

struct FoodSourcesTests {
    @Test func `module loads`() {
        #expect(FoodSources.moduleName == "FoodSources")
    }
}
