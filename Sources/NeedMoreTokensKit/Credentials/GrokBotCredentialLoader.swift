import Foundation
import CommonCrypto

/// Supplies the Cursor access token Grok Bot saved on this Mac. Nil means the
/// weekly Grok Bot bar cannot be read; the SuperGrok bar must still render.
public protocol GrokBotTokenLoading: Sendable {
    func loadAccessToken(now: Date) -> String?
}

/// Grok Bot's weekly allowance is a Cursor session, not the SuperGrok pool in
/// `~/.grok/auth.json`. The desktop app stores that session in `sand-secrets.json`,
/// with the access token encrypted the way Chromium's safeStorage does (`v10` +
/// AES-128-CBC). The key is the login-keychain item "Grok Bot Safe Storage" /
/// "Grok Bot Key".
///
/// NMT does not read that item with SecItem. The app is not on the item's access
/// list, and background refreshes are not allowed to raise the Keychain dialog,
/// so SecItem returns nothing and the bar never appears. `/usr/bin/security` is
/// already allowed to read the item. NMT asks it for the password and decrypts
/// locally. It does not write `sand-secrets.json`.
public struct GrokBotCredentialLoader: GrokBotTokenLoading, Sendable {
    public static let keychainService = "Grok Bot Safe Storage"
    public static let keychainAccount = "Grok Bot Key"

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    private let url: URL
    /// Test double. Production passes nil and reads the password through
    /// `/usr/bin/security` instead of SecItem.
    private let keychain: (any KeychainReading)?

    public init(url: URL = GrokBotCredentialLoader.defaultURL,
                keychain: (any KeychainReading)? = nil) {
        self.url = url
        self.keychain = keychain
    }

    public func loadAccessToken(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(SecretsFile.self, from: data),
              let accountsData = envelope.cursorAccounts.data(using: .utf8),
              let accounts = try? JSONDecoder().decode(AccountsFile.self, from: accountsData) else {
            return nil
        }
        let record = accounts.active.flatMap { accounts.accounts[$0] } ?? accounts.accounts.values.first
        guard let stored = record?.accessToken, !stored.isEmpty else { return nil }
        guard let password = passwordBytes(),
              let token = ChromiumSafeStorage.open(base64: stored, password: password),
              !token.isEmpty else {
            return nil
        }
        // A JWT with no `exp` is not treated as dead. Grok Bot rewrites this file
        // when it refreshes; NMT does not mint a new token itself.
        if CredentialExpiry.codexAccessTokenKnownExpired(token, now: now) { return nil }
        return token
    }

    private func passwordBytes() -> Data? {
        if let keychain {
            return try? keychain.readGenericPassword(service: Self.keychainService, account: Self.keychainAccount)
        }
        return Self.passwordFromSecurityCLI()
    }

    /// `security -w` prints the password and a trailing newline. A dialog would
    /// block a menu-bar refresh, so this gives up after a few seconds.
    static func passwordFromSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", keychainAccount,
            "-w",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        if data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : data
    }

    private struct SecretsFile: Decodable {
        let cursorAccounts: String
        enum CodingKeys: String, CodingKey { case cursorAccounts = "cursor-accounts" }
    }

    private struct AccountsFile: Decodable {
        let active: String?
        let accounts: [String: Account]

        struct Account: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken = "cursor-access-token" }
        }
    }
}

/// Chromium / Electron safeStorage on macOS. Password comes from the app's
/// "Safe Storage" keychain item. PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003
/// rounds, 16-byte key. AES-128-CBC, IV sixteen 0x20 bytes. Ciphertext is the
/// bytes after the `v10` prefix.
enum ChromiumSafeStorage {
    static func open(base64 blob: String, password: Data) -> String? {
        guard let raw = Data(base64Encoded: blob) else { return nil }
        for candidate in passwordCandidates(password) {
            if let text = decryptV10(raw, password: candidate), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Keychain items sometimes carry a trailing NUL or newline that is not
    /// part of the password Chromium passed to PBKDF2.
    private static func passwordCandidates(_ password: Data) -> [Data] {
        var candidates = [password]
        var trimmed = password
        while let last = trimmed.last, last == 0 || last == 10 || last == 13 {
            trimmed.removeLast()
        }
        if trimmed != password, !trimmed.isEmpty {
            candidates.append(trimmed)
        }
        return candidates
    }

    private static func decryptV10(_ blob: Data, password: Data) -> String? {
        let prefix = Data("v10".utf8)
        guard blob.starts(with: prefix), blob.count > prefix.count else { return nil }
        let ciphertext = [UInt8](blob.dropFirst(prefix.count))
        guard !ciphertext.isEmpty, let key = deriveKey(password) else { return nil }
        var iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            &iv,
            ciphertext, ciphertext.count,
            &out, out.count,
            &moved)
        guard status == kCCSuccess, moved > 0 else { return nil }
        return String(bytes: out.prefix(moved), encoding: .utf8)
    }

    private static func deriveKey(_ password: Data) -> [UInt8]? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status: Int32 = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count)
            }
        }
        guard status == kCCSuccess else { return nil }
        return key
    }
}
