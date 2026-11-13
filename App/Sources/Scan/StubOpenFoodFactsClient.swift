#if DEBUG
    import FoodSources
    import Foundation
    import Synchronization

    /// An ``OpenFoodFactsClient`` that never touches the network, for tests and previews: answers from `products`,
    /// "not found" for anything else, or throws `failure` while it is set (e.g. `.offline`).
    final class StubOpenFoodFactsClient: OpenFoodFactsClient {
        private struct State {
            var products: [String: OFFProduct]
            var failure: OpenFoodFactsError?
            var requests: [String] = []
            var delay: Duration?
        }

        private let state: Mutex<State>

        init(products: [OFFProduct] = [], failure: OpenFoodFactsError? = nil) {
            state = Mutex(State(
                products: Dictionary(products.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first }),
                failure: failure,
            ))
        }

        /// Codes requested so far, in order.
        var requests: [String] {
            state.withLock { $0.requests }
        }

        func setFailure(_ failure: OpenFoodFactsError?) {
            state.withLock { $0.failure = failure }
        }

        /// Answers after `delay` (to test what happens while a lookup is in flight).
        func setDelay(_ delay: Duration?) {
            state.withLock { $0.delay = delay }
        }

        func add(_ product: OFFProduct) {
            state.withLock { $0.products[product.code] = product }
        }

        func product(barcode: String) async throws -> OFFProduct {
            if let delay = state.withLock({ $0.delay }) {
                try await Task.sleep(for: delay)
            }
            let result: Result<OFFProduct, OpenFoodFactsError> = state.withLock { state in
                state.requests.append(barcode)
                if let failure = state.failure {
                    return .failure(failure)
                }
                guard let product = state.products[barcode] else { return .failure(.notFound) }
                return .success(product)
            }
            return try result.get()
        }
    }
#endif
