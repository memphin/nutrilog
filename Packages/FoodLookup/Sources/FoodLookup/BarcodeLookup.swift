import Core
import FoodSources
import Foundation
import Persistence

/// What a barcode resolved to.
public enum BarcodeLookupResult: Hashable, Sendable {
    /// A food in the local database carries the code (custom food, or a saved copy of an online food).
    case local(FoodDetail)
    /// Open Food Facts has the product (from the network or the product cache). Not saved as a food yet: save it
    /// with `FoodRepository.saveRemoteCopy(product.draft)` before logging.
    case remote(RemoteProduct)
    /// Neither the local database nor Open Food Facts knows the code. `barcode` is the most likely normalized key,
    /// to prefill a new custom food.
    case notFound(barcode: String)
}

/// A product found on Open Food Facts by ``BarcodeLookup``.
public struct RemoteProduct: Hashable, Sendable {
    /// Where the answer came from.
    public enum Origin: Hashable, Sendable {
        /// Fetched from OFF just now.
        case network
        /// From the product cache, younger than the cache policy's product TTL.
        case cache
        /// From an expired cache entry, because OFF could not be reached. The UI may say the data may be outdated.
        case staleCache
    }

    /// The normalized key the product was found under; also ``draft``'s barcode.
    public var barcode: String
    public var draft: FoodDraft
    /// ``draft``'s data quality as persisted (`partialMacros` → show the "complete nutrition" prompt, SPEC §9).
    public var quality: DataQuality
    /// When OFF answered.
    public var fetchedAt: Date
    public var origin: Origin

    public init(barcode: String, draft: FoodDraft, quality: DataQuality, fetchedAt: Date, origin: Origin) {
        self.barcode = barcode
        self.draft = draft
        self.quality = quality
        self.fetchedAt = fetchedAt
        self.origin = origin
    }

    /// True when served from an expired cache entry because OFF could not be reached.
    public var isStale: Bool {
        origin == .staleCache
    }
}

/// Why a barcode could not be resolved. A product OFF doesn't have is not an error: see
/// ``BarcodeLookupResult/notFound(barcode:)``.
public enum BarcodeLookupError: Error, Hashable, Sendable {
    /// The code isn't a valid retail barcode (no candidates).
    case invalidBarcode
    /// No connection, and nothing usable in the cache.
    case offline
    /// OFF could not answer (timeout, rate limit, server error, unusable response), and nothing usable in the cache.
    case unavailable(OpenFoodFactsError)
}

/// The barcode lookup pipeline (backlog #19, SPEC §9, FR-11):
/// local `food_barcode` → `off_product_cache` → Open Food Facts → cache the answer.
///
/// Every step tries each candidate key in order (an 8-digit code can be an EAN-8 or a UPC-E), so the most likely
/// reading wins: the local database is searched for all candidates first; then, per candidate, a fresh cache entry
/// answers without a request, otherwise OFF is asked. OFF's "not found" is cached too (a negative entry with a
/// shorter TTL) so repeated scans of an unknown product don't query OFF every time.
///
/// When OFF can't be reached, an expired cached product is returned rather than failing (``RemoteProduct/Origin/staleCache``);
/// with nothing usable cached the lookup throws ``BarcodeLookupError/offline`` (no connection) or
/// ``BarcodeLookupError/unavailable(_:)`` (any other failure) — distinct from not-found. An expired negative entry
/// is not trusted offline. After the first network failure no further candidate is requested.
public struct BarcodeLookup: Sendable {
    /// How long cache entries are trusted and kept.
    public struct CachePolicy: Hashable, Sendable {
        /// A cached product is fresh for this long (SPEC §7.3: 30 days).
        public var productTTL: TimeInterval
        /// A cached "not found" is fresh for this long: shorter, since products are added to OFF all the time.
        public var notFoundTTL: TimeInterval
        /// Entries older than this are deleted by ``BarcodeLookup/evictExpiredCache(in:policy:clock:)``.
        public var evictionAge: TimeInterval

        public init(productTTL: TimeInterval, notFoundTTL: TimeInterval, evictionAge: TimeInterval) {
            self.productTTL = productTTL
            self.notFoundTTL = notFoundTTL
            self.evictionAge = evictionAge
        }

        static let day: TimeInterval = 86400

        /// Products 30 days, not-found answers 7 days, eviction after 90 days.
        public static let standard = CachePolicy(productTTL: 30 * day, notFoundTTL: 7 * day, evictionAge: 90 * day)
    }

    let foods: FoodRepository
    let cache: OFFProductCache
    let client: any OpenFoodFactsClient
    let policy: CachePolicy
    let clock: AppClock
    /// The language products are named in (Settings → Food names, resolved): in Croatian, a product's Croatian name
    /// comes first (``OFFFoodMapper``). Applies to new products only: a food already saved keeps its name.
    let nameLanguage: FoodNameLanguage

    public init(
        database: AppDatabase,
        client: any OpenFoodFactsClient,
        nameLanguage: FoodNameLanguage,
        policy: CachePolicy = .standard,
        clock: AppClock = .system,
    ) {
        foods = FoodRepository(database, clock: clock)
        cache = OFFProductCache(database, clock: clock)
        self.client = client
        self.nameLanguage = nameLanguage
        self.policy = policy
        self.clock = clock
    }

    /// Resolves a scanned or typed code; `symbology` disambiguates 8-digit codes (`Barcode.candidates`).
    ///
    /// Throws ``BarcodeLookupError``, `CancellationError`, or a database error.
    public func resolve(_ code: String, symbology: Barcode.Symbology = .unknown) async throws -> BarcodeLookupResult {
        try await resolve(candidates: Barcode.candidates(code, symbology: symbology))
    }

    /// Resolves a code given as its normalized candidate keys, most likely first, e.g. the scanner's
    /// `ScannedBarcode.candidates`. Each key is normalized again (a no-op for normalized keys); invalid ones are dropped.
    ///
    /// Throws ``BarcodeLookupError``, `CancellationError`, or a database error.
    public func resolve(candidates: [String]) async throws -> BarcodeLookupResult {
        var keys: [String] = []
        for candidate in candidates {
            // Already-normalized keys stay as they are; anything else is normalized, and invalid codes are dropped.
            if let key = Barcode.normalize(candidate), !keys.contains(key) {
                keys.append(key)
            }
        }
        guard let primary = keys.first else { throw BarcodeLookupError.invalidBarcode }

        if let local = try foods.food(barcodes: keys) {
            return .local(local)
        }

        var failure: OpenFoodFactsError?
        for key in keys {
            if let product = try await remoteProduct(for: key, failure: &failure) {
                return .remote(product)
            }
        }

        switch failure {
        case nil:
            return .notFound(barcode: primary)
        case .offline?:
            throw BarcodeLookupError.offline
        case let error?:
            throw BarcodeLookupError.unavailable(error)
        }
    }

    /// The product for one candidate key from the cache or OFF; `nil` when OFF has none under this key, or when OFF
    /// can't be reached and nothing usable is cached. Records the first network failure in `failure`; once it is
    /// set, OFF is not asked again (one 8 s timeout per scan is enough).
    private func remoteProduct(for key: String, failure: inout OpenFoodFactsError?) async throws -> RemoteProduct? {
        // A broken cache row is treated as missing: the network answer replaces it.
        let entry = (try? cache.entry(barcode: key)) ?? nil
        let cached = entry.flatMap(Self.product(from:))
        if let entry, isFresh(entry) {
            if let cached {
                return remote(cached, key: key, fetchedAt: entry.fetchedAt, origin: .cache)
            }
            if entry.content == .notFound {
                return nil
            }
            // An unreadable cached product: ask OFF again.
        }

        if failure == nil {
            do {
                let product = try await client.product(barcode: key)
                store(product, key: key)
                return remote(product, key: key, fetchedAt: clock.now(), origin: .network)
            } catch OpenFoodFactsError.notFound {
                try? cache.storeNotFound(barcode: key) // best effort: a failed cache write must not hide the answer
                return nil
            } catch let error as OpenFoodFactsError {
                failure = error
            }
        }

        // OFF can't be reached: an expired product beats failing.
        guard let cached, let entry else { return nil }
        return remote(cached, key: key, fetchedAt: entry.fetchedAt, origin: .staleCache)
    }

    // MARK: - Cache eviction

    /// Deletes cache entries older than the policy's eviction age; returns how many were deleted.
    @discardableResult
    public func evictExpiredCache() throws -> Int {
        try cache.evictEntries(olderThan: policy.evictionAge)
    }

    /// ``evictExpiredCache()`` without a client, for app launch.
    @discardableResult
    public static func evictExpiredCache(
        in database: AppDatabase,
        policy: CachePolicy = .standard,
        clock: AppClock = .system,
    ) throws -> Int {
        try OFFProductCache(database, clock: clock).evictEntries(olderThan: policy.evictionAge)
    }

    // MARK: - Helpers

    private func isFresh(_ entry: OFFProductCacheEntry) -> Bool {
        let ttl = entry.content == .notFound ? policy.notFoundTTL : policy.productTTL
        let age = entry.age(at: clock.now())
        return age >= 0 && age < ttl // a future timestamp (clock change) counts as expired
    }

    private func remote(_ product: OFFProduct, key: String, fetchedAt: Date, origin: RemoteProduct.Origin) -> RemoteProduct {
        var draft = OFFFoodMapper.map(product, language: nameLanguage)
        draft.barcode = key // link the copy to the key it was found under, which may differ from OFF's code
        if draft.sourceID.isEmpty {
            draft.sourceID = key
        }
        return RemoteProduct(barcode: key, draft: draft, quality: DataQuality(draft.dataQuality), fetchedAt: fetchedAt, origin: origin)
    }

    /// Caches `product` under `key`. Best effort: a failed cache write must not hide the product.
    private func store(_ product: OFFProduct, key: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(product) else { return }
        try? cache.storeProduct(barcode: key, json: json, lastModifiedT: product.lastModifiedT)
    }

    /// The cached product, or `nil` for a not-found entry or JSON that no longer decodes.
    private static func product(from entry: OFFProductCacheEntry) -> OFFProduct? {
        guard case let .product(json, _) = entry.content else { return nil }
        return try? JSONDecoder().decode(OFFProduct.self, from: json)
    }
}
