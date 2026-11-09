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

    func add(_ product: OFFProduct) {
        state.withLock { $0.products[product.code] = product }
    }

    func product(barcode: String) async throws -> OFFProduct {
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
