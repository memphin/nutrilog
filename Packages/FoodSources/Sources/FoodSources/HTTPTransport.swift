import Foundation

/// Sends one HTTP request. The seam that lets tests and previews replace the network; online clients take one in
/// their initializer.
public protocol HTTPTransport: Sendable {
    /// Throws `URLError` for network failures; non-2xx statuses are returned, not thrown.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// ``HTTPTransport`` over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// A dedicated session that fails fast instead of waiting for connectivity, with `timeout` seconds as both the
    /// idle and the whole-transfer limit.
    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
