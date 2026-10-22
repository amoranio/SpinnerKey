import Foundation
#if canImport(Security)
import Security
#endif

/// Where management keys live. The only implementation that ships is the macOS Keychain.
public protocol SecretStore {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

#if canImport(Security)
/// Generic-password items in the login keychain, readable only on this Mac
/// (never synced to iCloud) and only by SpinnerKey without a user prompt.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.spinnerkey") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SpinnerKeyError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Checks for the item without loading the secret into memory.
    public func contains(account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SpinnerKeyError.keychain(status) }

        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "SpinnerKey (\(account))"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SpinnerKeyError.keychain(addStatus) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpinnerKeyError.keychain(status)
        }
    }
}
#endif
