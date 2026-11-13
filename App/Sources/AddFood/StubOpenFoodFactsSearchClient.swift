#if DEBUG
    import Core
    import FoodSources
    import Foundation

    /// An ``OpenFoodFactsSearchClient`` that never touches the network, for tests and previews: finds nothing.
    struct StubOpenFoodFactsSearchClient: OpenFoodFactsSearchClient {
        var rateLimitedUntil: Date? {
            nil
        }

        func search(query _: String, nameLanguage _: FoodNameLanguage) async throws -> [OFFSearchHit] {
            []
        }
    }
#endif
