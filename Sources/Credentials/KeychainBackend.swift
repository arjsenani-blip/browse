import Foundation
import Security
import Synchronization
import os

public enum PasswordStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A credential with the same host + username already exists.
    case duplicate
    case notFound
    case userPresenceRequired
    case invalidHost
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .duplicate: "A password for this site and username already exists."
        case .notFound: "The password could not be found."
        case .userPresenceRequired: "Authentication is required to access this password."
        case .invalidHost: "The website address is not valid."
        case .keychain(let status):
            "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
        }
    }
}

/// Which Keychain implementation is currently in use.
public enum KeychainFlavor: String, Sendable {
    /// The iOS-style data-protection keychain. Requires a signed app with a
    /// `keychain-access-groups` entitlement (i.e. a provisioning profile).
    case dataProtection
    /// The legacy file-based login keychain. Used automatically for ad-hoc / unsigned builds.
    case legacyFileBased
    /// In-memory storage for tests and previews.
    case inMemory
}

/// Storage seam for `PasswordStore`. All calls are synchronous and are made from the store actor.
protocol CredentialBackend: Sendable {
    var flavor: KeychainFlavor { get }
    func listAll() throws -> [Credential]
    func password(host: String, account: String) throws -> String?
    func add(_ credential: Credential, password: String) throws
    /// Updates the item currently keyed by (`host`, `account`). `password == nil` keeps the secret.
    func update(host: String, account: String, to credential: Credential, password: String?) throws
    func delete(host: String, account: String) throws
}

/// Non-secret attributes stored as JSON in `kSecAttrComment`.
struct CredentialMetadata: Codable {
    var id: UUID
    var created: Date
    var lastUsed: Date?
    var note: String?
    var v: Int = 1
}

/// `kSecClassInternetPassword` items, namespaced with `kSecAttrSecurityDomain` so we never
/// read or clobber Safari's / other apps' items in the login keychain.
///
/// Tries the data-protection keychain first; on `errSecMissingEntitlement` (-34018) it
/// permanently switches to the legacy file-based keychain for the rest of the process.
final class KeychainBackend: CredentialBackend {
    static let securityDomain = "app.aegis.browser.passwords"
    static let logger = Logger(subsystem: "app.aegis.browser", category: "Credentials")

    private let useDataProtection: Mutex<Bool>

    init(preferDataProtection: Bool = true) {
        useDataProtection = Mutex(preferDataProtection)
    }

    var flavor: KeychainFlavor {
        useDataProtection.withLock { $0 } ? .dataProtection : .legacyFileBased
    }

    // MARK: Fallback plumbing

    private func perform<T>(_ op: (_ dataProtection: Bool) -> (OSStatus, T)) -> (OSStatus, T) {
        let dp = useDataProtection.withLock { $0 }
        let result = op(dp)
        if dp, result.0 == errSecMissingEntitlement {
            useDataProtection.withLock { $0 = false }
            Self.logger.notice("Data-protection keychain unavailable (missing entitlement); using legacy login keychain")
            return op(false)
        }
        return result
    }

    private func baseQuery(_ dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: Self.securityDomain,
        ]
        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrSynchronizable as String] = false
        }
        return q
    }

    private func itemQuery(_ dp: Bool, host: String, account: String) -> [String: Any] {
        var q = baseQuery(dp)
        q[kSecAttrServer as String] = host
        q[kSecAttrAccount as String] = account
        return q
    }

    private func attributes(for c: Credential) -> [String: Any] {
        let meta = CredentialMetadata(id: c.id, created: c.created, lastUsed: c.lastUsed, note: c.note)
        let json = (try? JSONEncoder.metadata.encode(meta)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return [
            kSecAttrServer as String: c.host,
            kSecAttrAccount as String: c.username,
            kSecAttrLabel as String: c.host,
            kSecAttrDescription as String: "Vane web password",
            kSecAttrComment as String: json,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw PasswordStoreError.duplicate
        case errSecItemNotFound: throw PasswordStoreError.notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw PasswordStoreError.userPresenceRequired
        default: throw PasswordStoreError.keychain(status)
        }
    }

    // MARK: CredentialBackend

    func listAll() throws -> [Credential] {
        let (status, items): (OSStatus, [[String: Any]]) = perform { dp in
            var q = baseQuery(dp)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            var out: CFTypeRef?
            let s = SecItemCopyMatching(q as CFDictionary, &out)
            return (s, (out as? [[String: Any]]) ?? [])
        }
        if status == errSecItemNotFound { return [] }
        try Self.check(status)
        return items.compactMap(Self.credential(from:))
    }

    static func credential(from attrs: [String: Any]) -> Credential? {
        guard let host = attrs[kSecAttrServer as String] as? String else { return nil }
        let account = attrs[kSecAttrAccount as String] as? String ?? ""
        let keychainCreated = attrs[kSecAttrCreationDate as String] as? Date ?? Date()
        let meta = (attrs[kSecAttrComment as String] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder.metadata.decode(CredentialMetadata.self, from: $0) }
        return Credential(
            // Items without our metadata (should not happen) get a stable-per-session id.
            id: meta?.id ?? UUID(),
            host: host,
            username: account,
            created: meta?.created ?? keychainCreated,
            lastUsed: meta?.lastUsed,
            note: meta?.note
        )
    }

    func password(host: String, account: String) throws -> String? {
        let (status, data): (OSStatus, Data?) = perform { dp in
            var q = itemQuery(dp, host: host, account: account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let s = SecItemCopyMatching(q as CFDictionary, &out)
            return (s, out as? Data)
        }
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func add(_ credential: Credential, password: String) throws {
        let (status, _): (OSStatus, Void) = perform { dp in
            var q = baseQuery(dp)
            q.merge(attributes(for: credential)) { _, new in new }
            q[kSecValueData as String] = Data(password.utf8)
            if dp {
                q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            return (SecItemAdd(q as CFDictionary, nil), ())
        }
        try Self.check(status)
    }

    func update(host: String, account: String, to credential: Credential, password: String?) throws {
        let (status, _): (OSStatus, Void) = perform { dp in
            let q = itemQuery(dp, host: host, account: account)
            var attrs = attributes(for: credential)
            if let password { attrs[kSecValueData as String] = Data(password.utf8) }
            return (SecItemUpdate(q as CFDictionary, attrs as CFDictionary), ())
        }
        try Self.check(status)
    }

    func delete(host: String, account: String) throws {
        let (status, _): (OSStatus, Void) = perform { dp in
            (SecItemDelete(itemQuery(dp, host: host, account: account) as CFDictionary), ())
        }
        try Self.check(status)
    }
}

/// In-memory backend for tests and SwiftUI previews.
final class InMemoryBackend: CredentialBackend {
    private struct Key: Hashable { var host: String; var account: String }
    private let items = Mutex<[Key: (Credential, String)]>([:])

    var flavor: KeychainFlavor { .inMemory }

    func listAll() throws -> [Credential] {
        items.withLock { $0.values.map { $0.0 } }
    }

    func password(host: String, account: String) throws -> String? {
        items.withLock { $0[Key(host: host, account: account)]?.1 }
    }

    func add(_ credential: Credential, password: String) throws {
        try items.withLock { dict in
            let key = Key(host: credential.host, account: credential.username)
            guard dict[key] == nil else { throw PasswordStoreError.duplicate }
            dict[key] = (credential.redacted, password)
        }
    }

    func update(host: String, account: String, to credential: Credential, password: String?) throws {
        try items.withLock { dict in
            let old = Key(host: host, account: account)
            guard let existing = dict[old] else { throw PasswordStoreError.notFound }
            let new = Key(host: credential.host, account: credential.username)
            if new != old, dict[new] != nil { throw PasswordStoreError.duplicate }
            dict[old] = nil
            dict[new] = (credential.redacted, password ?? existing.1)
        }
    }

    func delete(host: String, account: String) throws {
        try items.withLock { dict in
            guard dict.removeValue(forKey: Key(host: host, account: account)) != nil else {
                throw PasswordStoreError.notFound
            }
        }
    }
}

extension JSONEncoder {
    static var metadata: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }
}

extension JSONDecoder {
    static var metadata: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
