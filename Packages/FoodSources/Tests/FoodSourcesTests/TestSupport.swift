import Foundation
import Synchronization
import Testing
@testable import FoodSources

/// JSON payloads shaped like real responses: OFF v2 in `Fixtures/OFF`, FDC search in `Fixtures/USDA`.
enum Fixture {
    static func data(_ name: String, in directory: String = "OFF") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(directory)"))
        return try Data(contentsOf: url)
    }

    static func product(_ name: String) throws -> OFFProduct {
        try #require(OFFProductResponse.parse(data(name))?.product, "fixture \(name) has no product")
    }

    static func draft(_ name: String) throws -> FoodDraft {
        try OFFFoodMapper.map(product(name))
    }
}

/// True when `value` is within `tolerance` of `expected`. Keeps arithmetic out of `#expect` (CI type-checker limits).
func isClose(_ value: Double?, _ expected: Double, tolerance: Double = 0.01) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Scripted ``HTTPTransport``: answers with `replies` in order (the last one repeats) and records every request.
final class StubTransport: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, Data, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private struct State {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ replies: [Reply]) {
        precondition(!replies.isEmpty)
        state = Mutex(State(replies: replies))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state in
            state.requests.append(request)
            return state.replies.count > 1 ? state.replies.removeFirst() : state.replies[0]
        }
        switch reply {
        case let .http(status, body, headers):
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
            return (body, response)
        case let .failure(code):
            throw URLError(code)
        }
    }
}

/// Records backoff delays instead of sleeping.
final class SleepRecorder: Sendable {
    private let recorded = Mutex<[Duration]>([])

    var delays: [Duration] {
        recorded.withLock { $0 }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] delay in recorded.withLock { $0.append(delay) } }
    }
}
