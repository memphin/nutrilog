import Foundation
import Security
import Synchronization

/// Where the user-entered USDA FoodData Central key lives (ADR-0004 option 1). Errors never carry the key.
protocol USDAKeyStoring: Sendable {
    /// The saved key, or `nil` when none is saved.
    func load() throws -> String?
    /// Saves `key`, replacing any saved one.
    func save(_ key: String) throws
    /// Removes the saved key; no error when there is none.
    func delete() throws
}

/// A Keychain call failed. Carries only the `OSStatus`.
struct KeychainError: LocalizedError, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        "Keychain error \(status)"
    }

    var errorDescription: String? {
        String(localized: "Keychain error \(String(status))")
    }
}

/// ``USDAKeyStoring`` in the Keychain: a generic password, this device only, readable after the first unlock.
struct KeychainUSDAKeyStore: USDAKeyStoring {
    /// Keeps the app's former name (Nutrilog) so a key saved before the rename is still found.
    var service = "hr.ivanjuric.nutrilog.usda-fdc"
    var account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(bytes: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// ``USDAKeyStoring`` in memory, for previews and tests.
final class InMemoryUSDAKeyStore: USDAKeyStoring {
    private let key: Mutex<String?>

    init(_ key: String? = nil) {
        self.key = Mutex(key)
    }

    func load() throws -> String? {
        key.withLock { $0 }
    }

    func save(_ key: String) throws {
        self.key.withLock { $0 = key }
    }

    func delete() throws {
        key.withLock { $0 = nil }
    }
}
