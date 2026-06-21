import Foundation
import Security

/// Keychain-backed `StorageService` for secrets (auth tokens, client memories).
///
/// Entries are stored as device-only generic passwords with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to background
/// runs after the first unlock, but never synced to iCloud and never included
/// in device backups. On a captured device the values are protected by the
/// Secure Enclave-backed class key rather than sitting in plaintext.
public final class KeychainStorage: StorageService {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, value: String?) {
        let query = baseQuery(key)
        guard let value = value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Routes sensitive keys to a secure backend (Keychain) and everything else to
/// a standard backend (UserDefaults). Non-secret UI preferences stay where
/// they are; credentials and client memories are encrypted at rest.
///
/// The backends are injectable so the routing can be unit-tested without
/// touching the real Keychain.
public final class SecureStorageService: StorageService {
    private let secure: StorageService
    private let standard: StorageService
    private let explicitSecureKeys: Set<String>

    public init(
        secure: StorageService,
        standard: StorageService,
        secureKeys: Set<String> = []
    ) {
        self.secure = secure
        self.standard = standard
        self.explicitSecureKeys = secureKeys
    }

    /// Production default: Keychain for secrets, UserDefaults for the rest.
    public static func makeDefault(
        prefix: String,
        secureKeys: Set<String> = []
    ) -> SecureStorageService {
        SecureStorageService(
            secure: KeychainStorage(service: "com.makemore.agent.\(prefix)"),
            standard: UserDefaultsStorage(prefix: prefix),
            secureKeys: secureKeys
        )
    }

    /// A key is sensitive if explicitly listed, or it names a credential or a
    /// client memory. The substring fallback keeps custom token-key names
    /// protected even when the host app renames `anonymousTokenKey`.
    func isSecure(_ key: String) -> Bool {
        if explicitSecureKeys.contains(key) { return true }
        let k = key.lowercased()
        return k.contains("token") || k.contains("memor")
            || k.contains("secret") || k.contains("auth")
    }

    public func get(_ key: String) -> String? {
        (isSecure(key) ? secure : standard).get(key)
    }

    public func set(_ key: String, value: String?) {
        (isSecure(key) ? secure : standard).set(key, value: value)
    }
}
