import Foundation

/// A saved website login.
///
/// `password` is `nil` for credentials returned by listing APIs; the secret is only
/// read from the Keychain on demand (see `PasswordStore.revealPassword(for:reason:)`
/// and `PasswordStore.passwordForFilling(_:reason:)`). `description` never includes it.
public struct Credential: Sendable, Hashable, Identifiable, Codable, CustomStringConvertible {
    public var id: UUID
    /// Normalized host (lowercased, no trailing dot), e.g. `accounts.example.com`.
    public var host: String
    public var username: String
    /// Only populated when explicitly fetched. Never logged.
    public var password: String?
    public var created: Date
    public var lastUsed: Date?
    public var note: String?

    public init(
        id: UUID = UUID(),
        host: String,
        username: String,
        password: String? = nil,
        created: Date = Date(),
        lastUsed: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.host = RegistrableDomain.normalize(host)
        self.username = username
        self.password = password
        self.created = created
        self.lastUsed = lastUsed
        self.note = note
    }

    /// Copy without the secret.
    public var redacted: Credential {
        var c = self
        c.password = nil
        return c
    }

    public var description: String {
        "Credential(id: \(id), host: \(host), username: <redacted>, password: <redacted>)"
    }
}
