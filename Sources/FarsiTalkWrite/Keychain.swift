import Foundation
import Security

/// One generic-password item per provider profile: service is constant, account
/// is the provider id. Keeping them separate means switching free ↔ paid ↔
/// OpenRouter never disturbs a key you already saved.
enum Keychain {
    static let service = "com.shahram.farsitalkwrite"

    /// In-memory cache of what we have already read.
    ///
    /// This is not an optimisation, it is a correctness fix: every Keychain read
    /// can raise a system authorisation prompt, and the UI polls permission state
    /// on a timer. Without caching, that turns into a stream of "wants to use your
    /// confidential information" dialogs. Reads happen once per provider per
    /// launch; writes and deletes invalidate the entry.
    private static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ providerID: String) -> String?? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[providerID]
    }

    private static func store(_ value: String?, for providerID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[providerID] = value
    }

    private static func invalidate(_ providerID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeValue(forKey: providerID)
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(msg)"
            }
        }
    }

    static func set(_ value: String, forProvider providerID: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attrs: [String: Any] = [kSecValueData as String: data]
            let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
            store(value, for: providerID)

        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "FarsiTalkWrite — \(providerID)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.unexpectedStatus(result) }
            store(value, for: providerID)

        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func get(forProvider providerID: String) -> String? {
        if let hit = cached(providerID) { return hit }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else {
            // Cache the absence too, so a missing key does not re-prompt on
            // every UI refresh either.
            store(nil, for: providerID)
            return nil
        }

        store(string, for: providerID)
        return string
    }

    static func delete(forProvider providerID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
        SecItemDelete(query as CFDictionary)
        invalidate(providerID)
    }

    static func hasKey(forProvider providerID: String) -> Bool {
        get(forProvider: providerID) != nil
    }

    /// For display in Settings and --check. Never logs or returns the full key.
    static func masked(forProvider providerID: String) -> String {
        guard let key = get(forProvider: providerID) else { return "— not set —" }
        guard key.count > 10 else { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + String(repeating: "•", count: 8) + key.suffix(4)
    }
}
