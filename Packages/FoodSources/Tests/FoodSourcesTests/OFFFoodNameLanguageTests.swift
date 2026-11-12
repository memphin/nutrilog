import Core
import Foundation
import Testing
@testable import FoodSources

/// Settings → Food names for Open Food Facts products: in Croatian, a product's Croatian name (`product_name_hr`)
/// becomes the name and the main name the local one; otherwise the main name stays first.
struct OFFFoodNameLanguageTests {
    private static let nutriments: [String: Double] = [
        "energy-kcal_100g": 400, "proteins_100g": 10, "carbohydrates_100g": 60, "fat_100g": 12,
    ]

    private func product(name: String?, hr: String?, en: String? = nil) -> OFFProduct {
        OFFProduct(code: "3850102508648", productName: name, productNameHR: hr, productNameEN: en, nutriments: Self.nutriments)
    }

    @Test func `croatian picks the croatian name with the main name as local`() {
        let names = OFFFoodMapper.names(product(name: "Vegeta food seasoning", hr: "Vegeta dodatak jelima"), language: .croatian)
        #expect(names.name == "Vegeta dodatak jelima")
        #expect(names.local == "Vegeta food seasoning")
    }

    @Test func `english keeps the main name with the croatian name as local`() {
        let names = OFFFoodMapper.names(product(name: "Vegeta food seasoning", hr: "Vegeta dodatak jelima"), language: .english)
        #expect(names.name == "Vegeta food seasoning")
        #expect(names.local == "Vegeta dodatak jelima")
    }

    @Test func `without a croatian name both languages give the main name`() {
        for language in FoodNameLanguage.allCases {
            let names = OFFFoodMapper.names(product(name: "Nutella", hr: nil), language: language)
            #expect(names.name == "Nutella")
            #expect(names.local == nil)
        }
    }

    @Test func `the same croatian and main name gives one name`() {
        let names = OFFFoodMapper.names(product(name: "Dorina", hr: "DORINA"), language: .croatian)
        #expect(names.name == "Dorina")
        #expect(names.local == nil)
    }

    @Test func `only a croatian name is the name in either language`() {
        for language in FoodNameLanguage.allCases {
            let names = OFFFoodMapper.names(product(name: nil, hr: "Čokolada"), language: language)
            #expect(names.name == "Čokolada")
            #expect(names.local == nil)
        }
    }

    @Test func `croatian with an english name and no main name`() {
        let names = OFFFoodMapper.names(product(name: nil, hr: "Keksi", en: "Biscuits"), language: .croatian)
        #expect(names.name == "Keksi")
        #expect(names.local == "Biscuits")
    }

    @Test func `map takes the language`() throws {
        let draft = try OFFFoodMapper.map(Fixture.product("podravka_vegeta_hr"), language: .croatian)
        #expect(draft.name == "Vegeta dodatak jelima s povrćem")
        #expect(draft.nameLocal == "Vegeta food seasoning with vegetables")
        // English is today's behaviour.
        let english = try OFFFoodMapper.map(Fixture.product("podravka_vegeta_hr"), language: .english)
        #expect(english.name == "Vegeta food seasoning with vegetables")
        #expect(english.nameLocal == "Vegeta dodatak jelima s povrćem")
        #expect(try OFFFoodMapper.map(Fixture.product("podravka_vegeta_hr")) == english)
    }

    @Test func `search results come in the language asked for`() async throws {
        let body = Data("""
        {"count": 1, "products": [{"code": "3850104012341", "product_name": "Vegeta food seasoning",
          "product_name_hr": "Vegeta dodatak jelima",
          "nutriments": {"energy-kcal_100g": 160, "proteins_100g": 9, "carbohydrates_100g": 25, "fat_100g": 1}}]}
        """.utf8)
        let client = OpenFoodFactsSearchHTTPClient(
            contact: "test", transport: StubTransport([.http(200, body), .http(200, body)]),
            throttle: OFFSearchThrottle(minimumInterval: .zero), sleep: { _ in },
        )
        let croatian = try await client.search(query: "vegeta", nameLanguage: .croatian)
        #expect(croatian.map(\.name) == ["Vegeta dodatak jelima"])
        #expect(croatian.map(\.nameLocal) == ["Vegeta food seasoning"])
        let english = try await client.search(query: "vegeta", nameLanguage: .english)
        #expect(english.map(\.name) == ["Vegeta food seasoning"])
    }

    @Test func `barcode lookup maps in the language asked for`() async throws {
        let transport = try StubTransport([.http(200, Fixture.data("podravka_vegeta_hr"))])
        let client = OpenFoodFactsHTTPClient(contact: "test", transport: transport)
        let draft = try await client.food(barcode: "3850104012341", nameLanguage: .croatian)
        #expect(draft.name == "Vegeta dodatak jelima s povrćem")
        #expect(draft.nameLocal == "Vegeta food seasoning with vegetables")
    }
}
