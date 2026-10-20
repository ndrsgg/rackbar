import Foundation
import Security

/// Hetzner tokens in the data protection Keychain, one item per key.
///
/// The token never goes anywhere else: not into UserDefaults, not onto a
/// command line, not into a log. Only `HetznerClient` builds an
/// `Authorization` header from it.
struct Keychain: Sendable {
    private let service = "app.rackbar.Rackbar.hetzner-token"

    func token(for key: String) -> String? {
        var query = item(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func store(_ token: String, for key: String, label: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(item(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = item(key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Rackbar – Hetzner Cloud (\(label))"
            // Readable by the poll after login, never synced to other devices.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(item(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func item(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain refused: \(message)"
    }
}
