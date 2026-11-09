import Foundation
import Testing
@testable import FoodSources

/// Serves canned OFF responses to a `URLSession`, keyed by the barcode in the path. Stateless, so it is safe with
/// parallel tests.
private final class OFFStubURLProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let found = url.path.contains("3017620422003")
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        let product = #"{"product_name":"Nutella","brands":"\#(userAgent)","nutriments":{"energy-kcal_100g":539}}"#
        let body = found
            ? #"{"code":"3017620422003","status":1,"product":\#(product)}"#
            : #"{"code":"0000000000000","status":0,"status_verbose":"product not found"}"#
        let response = HTTPURLResponse(
            url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct URLSessionTransportTests {
    private func makeClient() -> OpenFoodFactsHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OFFStubURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        return OpenFoodFactsHTTPClient(contact: "https://github.com/memphin/nutrilog", transport: transport)
    }

    @Test func `client works end to end over URLSession`() async throws {
        let product = try await makeClient().product(barcode: "3017620422003")
        #expect(product.productName == "Nutella")
        #expect(product.nutriments["energy-kcal_100g"] == 539)
        // The stub echoes the User-Agent it received into `brands`.
        #expect(product.brands == "Nutrilog/1.0 (https://github.com/memphin/nutrilog)")
    }

    @Test func `HTTP 404 from URLSession is returned, not thrown, and maps to notFound`() async {
        await #expect(throws: OpenFoodFactsError.notFound) {
            try await makeClient().product(barcode: "0000000000000")
        }
    }

    @Test func `timeout initializer configures the session`() {
        let transport = URLSessionTransport(timeout: 8)
        #expect(transport.session.configuration.timeoutIntervalForRequest == 8)
        #expect(transport.session.configuration.timeoutIntervalForResource == 8)
        #expect(transport.session.configuration.waitsForConnectivity == false)
    }
}
