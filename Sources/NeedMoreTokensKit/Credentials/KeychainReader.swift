import Foundation
import Security

public protocol KeychainReading: Sendable {
    func readGenericPassword(service: String, account: String?) throws -> Data?
}

/// Controls whether this process may present the legacy Keychain "allow access"
/// dialog. NMT reads login-Keychain items it does not own (Claude Code, Antigravity);
/// macOS would prompt on any read the app lacks an ACL grant for. Disabling user
/// interaction makes such a read fail (errSecAuthFailed / errSecInteractionNotAllowed)
/// instead of popping a dialog — verified on macOS 26. This is the load-bearing
/// suppressor; the modern `kSecUseAuthenticationUI` query flag does NOT cover the
/// legacy ACL prompt. The app keeps interaction OFF for background refreshes and
/// briefly turns it ON only for an explicit, user-initiated "Enable native access".
public enum KeychainInteraction {
    /// Background-safe default: a read can never present a prompt.
    public static func disableBackgroundPrompts() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    /// Run `body` with the Keychain prompt temporarily permitted, then restore the
    /// background-safe state no matter how `body` exits. Use ONLY for a deliberate,
    /// user-initiated grant — never on the periodic refresh path.
    @discardableResult
    public static func withInteractionAllowed<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(true)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        return body()
    }
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

    /// True when the failure means "this app is not in the item's ACL and could not
    /// prompt to gain access" — i.e. a grant is needed, not that the data is corrupt.
    /// With background prompts disabled (see `KeychainInteraction`), an un-granted read
    /// returns `errSecAuthFailed`; `errSecInteractionNotAllowed` covers the same state
    /// on systems that report it instead.
    public var isAccessNotGranted: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    public var description: String {
        "Keychain read failed with OSStatus \(status)"
    }
}
