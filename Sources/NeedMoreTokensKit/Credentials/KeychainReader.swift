import Foundation
import Security

public protocol KeychainReading: Sendable {
    func readGenericPassword(service: String, account: String?) throws -> Data?
}

public struct SystemKeychainReader: KeychainReading {
    public init() {}

    public func readGenericPassword(service: String, account: String?) throws -> Data? {
        let query = KeychainQueryBuilder.genericPasswordQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainReadError(status: errSecInternalComponent)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainReadError(status: status)
        }
    }
}

public enum KeychainQueryBuilder {
    public static func genericPasswordQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}

public struct KeychainReadError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        "Keychain read failed with OSStatus \(status)"
    }
}
