import Core
import FoodSources
import Foundation
import Persistence
import Synchronization
@testable import FoodLookup

/// A clock tests can advance.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_200_000)) { // 2026-11-09 ~04:53 UTC
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(days: Double) {
        current.withLock { $0 = $0.addingTimeInterval(days * 86400) }
    }

    var appClock: AppClock {
        AppClock { [self] in now }
    }
}

/// Scripted ``OpenFoodFactsClient``: answers per barcode and records every request.
final class StubOFFClient: OpenFoodFactsClient {
    enum Reply: Sendable {
        case product(OFFProduct)
        case failure(OpenFoodFactsError)
        case cancelled
    }

    private struct State {
        var replies: [String: Reply]
        var requests: [String] = []
    }

    private let state: Mutex<State>

    /// Codes without a reply answer `.notFound`.
    init(_ replies: [String: Reply] = [:]) {
        state = Mutex(State(replies: replies))
    }

    var requests: [String] {
        state.withLock { $0.requests }
    }

    func set(_ barcode: String, _ reply: Reply) {
        state.withLock { $0.replies[barcode] = reply }
    }

    func product(barcode: String) async throws -> OFFProduct {
        let reply = state.withLock { state in
            state.requests.append(barcode)
            return state.replies[barcode] ?? .failure(.notFound)
        }
        switch reply {
        case let .product(product): return product
        case let .failure(error): throw error
        case .cancelled: throw CancellationError()
        }
    }
}

/// An OFF product with energy and all three macros per 100 g.
func offProduct(_ code: String, name: String = "Nutella", kcal: Double = 539) -> OFFProduct {
    OFFProduct(
        code: code,
        productName: name,
        brands: "Ferrero",
        servingSize: "15 g",
        servingQuantity: 15,
        nutriments: ["energy-kcal_100g": kcal, "proteins_100g": 6.3, "carbohydrates_100g": 57.5, "fat_100g": 30.9],
        lastModifiedT: 1_700_000_000,
    )
}

/// Database, clock, stub client and the pipeline over them.
struct Fixture {
    let db: AppDatabase
    let clock = TestClock()
    let client: StubOFFClient

    init(_ replies: [String: StubOFFClient.Reply] = [:]) throws {
        db = try AppDatabase.inMemory()
        client = StubOFFClient(replies)
    }

    var lookup: BarcodeLookup {
        BarcodeLookup(database: db, client: client, nameLanguage: .english, clock: clock.appClock)
    }

    var foods: FoodRepository {
        FoodRepository(db, clock: clock.appClock)
    }

    var cache: OFFProductCache {
        OFFProductCache(db, clock: clock.appClock)
    }
}

/// The remote product of a result, else `nil`.
extension BarcodeLookupResult {
    var remote: RemoteProduct? {
        if case let .remote(product) = self {
            return product
        }
        return nil
    }
}
