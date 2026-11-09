import FoodSources
import Foundation
import Synchronization
import Testing
@testable import Nutrilog

struct USDAKeySourceTests {
    @Test func `keychain key wins, then build config, then none`() {
        #expect(USDAKeySource.resolve(saved: "user", buildConfig: "build") == ("user", .keychain))
        #expect(USDAKeySource.resolve(saved: nil, buildConfig: "build") == ("build", .buildConfig))
        #expect(USDAKeySource.resolve(saved: "  ", buildConfig: " build ") == ("build", .buildConfig))
        #expect(USDAKeySource.resolve(saved: nil, buildConfig: nil) == (nil, .none))
        #expect(USDAKeySource.resolve(saved: "", buildConfig: "") == (nil, .none))
    }
}

/// A store whose Keychain calls fail, like a locked or entitlement-less Keychain.
private struct FailingKeyStore: USDAKeyStoring {
    func load() throws -> String? {
        throw KeychainError(status: -34018)
    }

    func save(_: String) throws {
        throw KeychainError(status: -34018)
    }

    func delete() throws {
        throw KeychainError(status: -34018)
    }
}

@MainActor
struct USDAKeyEnvironmentTests {
    private func environment(buildKey: String?, store: any USDAKeyStoring = InMemoryUSDAKeyStore()) -> AppEnvironment {
        AppEnvironment(
            database: .failed("unused"),
            config: AppConfig(usdaAPIKey: buildKey, offUserAgent: AppConfig.defaultUserAgent),
            bundledIndex: nil,
            usdaKeyStore: store,
        )
    }

    @Test func `without any key USDA is unavailable and the app still works`() async throws {
        let env = AppEnvironment.preview()
        #expect(env.usdaKeySource == .none)
        #expect(!env.usda.isAvailable)
        await #expect(throws: USDAError.missingAPIKey) {
            try await env.usda.search(query: "apple")
        }
        #expect(env.foods != nil)
        #expect(env.search != nil)
    }

    @Test func `build-config key makes USDA available`() {
        let env = environment(buildKey: "build-key")
        #expect(env.usdaKeySource == .buildConfig)
        #expect(env.usda.isAvailable)
    }

    @Test func `saved key overrides the build-config key; removing it falls back`() throws {
        let store = InMemoryUSDAKeyStore()
        let env = environment(buildKey: "build-key", store: store)
        try env.saveUSDAKey("  user-key \n")
        #expect(env.usdaKeySource == .keychain)
        #expect(try store.load() == "user-key")
        #expect(env.usda.isAvailable)

        try env.removeUSDAKey()
        #expect(env.usdaKeySource == .buildConfig)
        #expect(try store.load() == nil)
    }

    @Test func `saving a blank key does nothing; removing the only key makes USDA unavailable`() throws {
        let store = InMemoryUSDAKeyStore()
        let env = environment(buildKey: nil, store: store)
        try env.saveUSDAKey("   ")
        #expect(env.usdaKeySource == .none)
        #expect(try store.load() == nil)

        try env.saveUSDAKey("user-key")
        #expect(env.usda.isAvailable)
        try env.removeUSDAKey()
        #expect(env.usdaKeySource == .none)
        #expect(!env.usda.isAvailable)
    }

    @Test func `a saved key is picked up at launch`() {
        let env = environment(buildKey: nil, store: InMemoryUSDAKeyStore("saved-key"))
        #expect(env.usdaKeySource == .keychain)
        #expect(env.usda.isAvailable)
    }

    @Test func `an unreadable Keychain falls back to the build-config key; errors carry no key`() {
        let env = environment(buildKey: "build-key", store: FailingKeyStore())
        #expect(env.usdaKeySource == .buildConfig)
        #expect(throws: KeychainError.self) { try env.saveUSDAKey("secret-user-key") }
        do {
            try env.saveUSDAKey("secret-user-key")
        } catch {
            #expect(!error.localizedDescription.contains("secret-user-key"))
            #expect(error.localizedDescription.contains("-34018"))
        }
        #expect(env.usdaKeySource == .buildConfig)
        #expect(env.usdaKeychainUnreadable)
    }

    @Test func `a Keychain locked at launch is retried and its key then wins`() {
        let store = LockableKeyStore(key: "user-key")
        let env = environment(buildKey: nil, store: store)
        #expect(env.usdaKeychainUnreadable)
        #expect(env.usdaKeySource == .none) // nothing usable yet, but not reported as "no key stored"
        #expect(!env.usda.isAvailable)

        store.unlock()
        env.reloadUSDAKey()
        #expect(!env.usdaKeychainUnreadable)
        #expect(env.usdaKeySource == .keychain)
        #expect(env.usda.isAvailable)
    }

    @Test func `one rate limit: kept when the key is unchanged, reset when it changes`() async throws {
        let env = environment(buildKey: "build-key")
        let until = Date().addingTimeInterval(3600)
        env.usdaRateLimit.block(until: until)
        #expect(env.usda.rateLimitedUntil == until)

        env.reloadUSDAKey() // same key, e.g. app became active
        #expect(env.usda.rateLimitedUntil == until)
        await #expect(throws: USDAError.rateLimited(until: until)) {
            try await env.usda.search(query: "apple")
        }

        try env.saveUSDAKey("new-key")
        #expect(env.usda.rateLimitedUntil == nil)
        #expect(env.usdaRateLimit.blockedUntil(now: Date()) == nil)
    }
}

/// A Keychain that can't be read until `unlock()`, like one before the first unlock after a reboot.
private final class LockableKeyStore: USDAKeyStoring {
    private let state: Mutex<(locked: Bool, key: String?)>

    init(key: String?) {
        state = Mutex((true, key))
    }

    func unlock() {
        state.withLock { $0.locked = false }
    }

    func load() throws -> String? {
        try state.withLock { state in
            if state.locked {
                throw KeychainError(status: errSecInteractionNotAllowed)
            }
            return state.key
        }
    }

    func save(_ key: String) throws {
        state.withLock { $0.key = key }
    }

    func delete() throws {
        state.withLock { $0.key = nil }
    }
}

/// The real Keychain. The simulator test host may run without a Keychain entitlement (CI builds with
/// CODE_SIGNING_ALLOWED=NO); then the store reports `errSecMissingEntitlement` and the round trip is skipped.
struct KeychainUSDAKeyStoreTests {
    @Test func `save, load, overwrite and delete round trip`() throws {
        let store = KeychainUSDAKeyStore(service: "hr.ivanjuric.nutrilog.tests.\(UUID().uuidString)")
        do {
            try store.save("first")
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            return
        }
        defer { try? store.delete() }
        #expect(try store.load() == "first")
        try store.save("second")
        #expect(try store.load() == "second")
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete() // deleting nothing is fine
    }
}
