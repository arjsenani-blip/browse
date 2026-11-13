import Foundation

/// A login suggestion for a page. Contains no password.
public struct CredentialSuggestion: Sendable, Hashable, Identifiable {
    public var credential: Credential
    public var matchKind: HostMatchKind
    public var id: UUID { credential.id }
    /// e.g. "alice@example.com — example.com"
    public var displayTitle: String {
        let user = credential.username.isEmpty ? "(no username)" : credential.username
        return "\(user) — \(credential.host)"
    }
}

/// What the browser should offer after a login form was submitted.
public enum SubmitDecision: Sendable, Equatable {
    /// New login: show "Save password for <host>?"
    case offerSave(host: String, username: String)
    /// Known username with a different password: show "Update password?"
    case offerUpdate(credentialID: UUID, host: String, username: String)
    case nothing
}

/// The seam WebEngine talks to. Kept free of WebKit: WebEngine translates
/// `vaneAutofill` script messages into these calls, and injects the result of
/// `fillValues(for:)` with `window.__vaneFill(username, password)` in the
/// `vane-autofill` content world.
public protocol CredentialsCoordinating: Sendable {
    /// Called for `{type: "formsFound", host, hasPassword}`.
    func didFindForms(host: String) async -> [CredentialSuggestion]
    /// Called for `{type: "submitted", host, username, password}`.
    func didSubmit(host: String, username: String, password: String) async -> SubmitDecision
    /// Returns the secret for filling, gated by the fill session (Touch ID / password once
    /// per N minutes). nil if the user declined or the credential vanished.
    func fillValues(for suggestion: CredentialSuggestion) async -> (username: String, password: String)?
    /// User accepted the save / update prompt. The password is passed back by the caller,
    /// which held it from the submit message.
    func confirmSave(host: String, username: String, password: String) async throws
    func confirmUpdate(credentialID: UUID, password: String) async throws
    /// "Never save for this site".
    func neverSave(host: String) async
}

/// Default implementation backed by `PasswordStore`.
public actor CredentialsCoordinator: CredentialsCoordinating {
    public let store: PasswordStore
    /// Registrable domains the user chose "Never" for. In-memory; the app layer may persist
    /// via `neverSaveDomains` / `setNeverSaveDomains(_:)`.
    public private(set) var neverSaveDomains: Set<String> = []
    /// Max suggestions returned to the page UI.
    public var maxSuggestions = 8

    public init(store: PasswordStore) {
        self.store = store
    }

    public func setNeverSaveDomains(_ domains: Set<String>) {
        neverSaveDomains = Set(domains.map(RegistrableDomain.normalize))
    }

    public func didFindForms(host: String) async -> [CredentialSuggestion] {
        guard let matches = try? await store.matches(forHost: host) else { return [] }
        return matches.prefix(maxSuggestions).map {
            CredentialSuggestion(credential: $0.credential.redacted, matchKind: $0.kind)
        }
    }

    public func didSubmit(host rawHost: String, username: String, password: String) async -> SubmitDecision {
        let host = RegistrableDomain.normalize(rawHost)
        guard !host.isEmpty, !password.isEmpty else { return .nothing }
        guard !neverSaveDomains.contains(RegistrableDomain.registrableDomain(of: host)) else { return .nothing }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let matches = try? await store.matches(forHost: host) else { return .nothing }
        // Prefer an exact-host credential with this username, then a parent-domain one.
        if let existing = matches.first(where: { $0.credential.username == user })?.credential {
            let current = try? await store.rawPassword(for: existing)
            if current == password {
                try? await store.markUsed(id: existing.id)
                return .nothing
            }
            return .offerUpdate(credentialID: existing.id, host: existing.host, username: user)
        }
        return .offerSave(host: host, username: user)
    }

    public func fillValues(for suggestion: CredentialSuggestion) async -> (username: String, password: String)? {
        guard let filled = try? await store.passwordForFilling(suggestion.credential),
              let pw = filled.password else { return nil }
        return (filled.username, pw)
    }

    public func confirmSave(host: String, username: String, password: String) async throws {
        try await store.save(Credential(host: host, username: username, password: password, lastUsed: Date()))
    }

    public func confirmUpdate(credentialID: UUID, password: String) async throws {
        guard var c = try await store.credential(id: credentialID) else { throw PasswordStoreError.notFound }
        c.password = password
        c.lastUsed = Date()
        try await store.update(c)
    }

    public func neverSave(host: String) async {
        neverSaveDomains.insert(RegistrableDomain.registrableDomain(of: host))
    }
}
