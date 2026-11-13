import Foundation
import os

/// Vane's own password manager, backed by the macOS Keychain.
///
/// Apple offers no API for third-party browsers to read or write iCloud Keychain website
/// passwords, so these are stored as `kSecClassInternetPassword` items owned by Vane
/// (see `docs/research/01-apple-passwords.md`).
///
/// Listing APIs return credentials **without** passwords. Secrets are read only through
/// `revealPassword(for:reason:)` (always requires user presence) or
/// `passwordForFilling(_:reason:)` (requires user presence once per fill session).
/// Passwords and usernames are never logged.
public actor PasswordStore {
    private let backend: any CredentialBackend
    public let gate: UserPresenceGate
    private static let logger = Logger(subsystem: "app.aegis.browser", category: "Credentials")

    /// Keychain-backed store (data-protection keychain, falling back to the login keychain
    /// automatically when the app lacks the `keychain-access-groups` entitlement).
    public init(gate: UserPresenceGate = UserPresenceGate()) {
        self.backend = KeychainBackend()
        self.gate = gate
    }

    init(backend: any CredentialBackend, gate: UserPresenceGate) {
        self.backend = backend
        self.gate = gate
    }

    /// Volatile store for tests and previews.
    public static func inMemory(gate: UserPresenceGate = UserPresenceGate(authenticator: FixedAuthenticator(result: true))) -> PasswordStore {
        PasswordStore(backend: InMemoryBackend(), gate: gate)
    }

    /// Which keychain is in use. Before the first operation this reports the preferred flavor.
    public var keychainFlavor: KeychainFlavor { backend.flavor }

    // MARK: Queries (no secrets)

    public func allCredentials() throws -> [Credential] {
        try backend.listAll().sorted {
            ($0.host, $0.username.lowercased()) < ($1.host, $1.username.lowercased())
        }
    }

    /// Credentials usable on `host`: same host (`www.` insensitive) or saved for a parent
    /// domain within the same registrable domain. Never crosses registrable domains.
    /// Sorted exact-first, then most recently used.
    public func credentials(forHost host: String) throws -> [Credential] {
        try matches(forHost: host).map(\.credential)
    }

    public func matches(forHost host: String) throws -> [(credential: Credential, kind: HostMatchKind)] {
        let page = RegistrableDomain.normalize(host)
        guard !page.isEmpty else { return [] }
        return try backend.listAll()
            .compactMap { c in HostMatcher.match(credentialHost: c.host, pageHost: page).map { (c, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return (a.0.lastUsed ?? a.0.created) > (b.0.lastUsed ?? b.0.created)
            }
            .map { (credential: $0.0, kind: $0.1) }
    }

    public func credential(id: UUID) throws -> Credential? {
        try backend.listAll().first { $0.id == id }
    }

    // MARK: Mutations

    /// Saves a new credential. `credential.password` must be non-nil.
    /// Throws `.duplicate` if host + username already exists.
    @discardableResult
    public func save(_ credential: Credential) throws -> Credential {
        guard !credential.host.isEmpty else { throw PasswordStoreError.invalidHost }
        guard let password = credential.password else { throw PasswordStoreError.notFound }
        try backend.add(credential, password: password)
        Self.logger.info("Saved password for \(credential.host, privacy: .private(mask: .hash))")
        return credential.redacted
    }

    /// Updates the credential with `credential.id`. Host, username, note and lastUsed are taken
    /// from `credential`; the password changes only if `credential.password` is non-nil.
    @discardableResult
    public func update(_ credential: Credential) throws -> Credential {
        guard let existing = try self.credential(id: credential.id) else { throw PasswordStoreError.notFound }
        guard !credential.host.isEmpty else { throw PasswordStoreError.invalidHost }
        try backend.update(host: existing.host, account: existing.username, to: credential, password: credential.password)
        return credential.redacted
    }

    public func delete(_ credential: Credential) throws {
        try delete(id: credential.id)
    }

    public func delete(id: UUID) throws {
        guard let existing = try credential(id: id) else { throw PasswordStoreError.notFound }
        try backend.delete(host: existing.host, account: existing.username)
    }

    /// Records that a credential was just filled/used.
    public func markUsed(id: UUID, at date: Date = Date()) throws {
        guard var c = try credential(id: id) else { throw PasswordStoreError.notFound }
        c.lastUsed = date
        c.password = nil
        try backend.update(host: c.host, account: c.username, to: c, password: nil)
    }

    // MARK: Secrets

    /// Prompts for Touch ID / password. Always asks (no session reuse).
    public func authenticateUser(reason: String) async -> Bool {
        await gate.authenticateUser(reason: reason)
    }

    /// For the password manager UI: always requires user presence, then returns the
    /// credential with `password` populated.
    public func revealPassword(for credential: Credential, reason: String = "reveal a saved password") async throws -> Credential {
        guard await gate.authenticateUser(reason: reason) else { throw PasswordStoreError.userPresenceRequired }
        return try withPassword(credential)
    }

    /// For page autofill: requires user presence once per fill session (default 5 minutes,
    /// see `UserPresenceGate.fillSessionDuration`). Also bumps `lastUsed`.
    public func passwordForFilling(_ credential: Credential, reason: String = "fill your saved password") async throws -> Credential {
        guard await gate.ensureFillSession(reason: reason) else { throw PasswordStoreError.userPresenceRequired }
        let filled = try withPassword(credential)
        try? markUsed(id: credential.id)
        return filled
    }

    /// Ungated secret read. Module-internal: used for duplicate detection (import, save prompts).
    func rawPassword(for credential: Credential) throws -> String? {
        try backend.password(host: credential.host, account: credential.username)
    }

    private func withPassword(_ credential: Credential) throws -> Credential {
        guard let pw = try rawPassword(for: credential) else { throw PasswordStoreError.notFound }
        var c = credential
        c.password = pw
        return c
    }
}
