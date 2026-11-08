import Foundation
import LocalAuthentication

/// Something that can verify the user is present (Touch ID / Apple Watch / login password).
public protocol UserPresenceAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

/// `LAContext`-backed authenticator using `.deviceOwnerAuthentication`
/// (biometrics with password fallback). A fresh context is created per request so no
/// authentication state leaks between calls; session reuse is handled by `UserPresenceGate`.
public struct LocalAuthenticationAuthenticator: UserPresenceAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode / biometrics configured at all: we cannot prove presence.
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Test/preview authenticator with a fixed answer.
public struct FixedAuthenticator: UserPresenceAuthenticating {
    public let result: Bool
    public init(result: Bool) { self.result = result }
    public func authenticate(reason: String) async -> Bool { result }
}

/// Gates secret access behind user presence.
///
/// - `authenticateUser(reason:)` always prompts (used before revealing a password in the manager UI).
/// - `ensureFillSession(reason:)` prompts at most once per `fillSessionDuration`
///   (default 5 minutes) for page autofill.
public actor UserPresenceGate {
    public var fillSessionDuration: TimeInterval
    private let authenticator: any UserPresenceAuthenticating
    private let now: @Sendable () -> Date
    private var lastFillAuthentication: Date?
    private var inFlight: Task<Bool, Never>?

    public init(
        authenticator: any UserPresenceAuthenticating = LocalAuthenticationAuthenticator(),
        fillSessionDuration: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authenticator = authenticator
        self.fillSessionDuration = fillSessionDuration
        self.now = now
    }

    public func setFillSessionDuration(_ seconds: TimeInterval) {
        fillSessionDuration = max(0, seconds)
    }

    /// Always asks the user. A success also refreshes the fill session.
    public func authenticateUser(reason: String) async -> Bool {
        let ok = await authenticator.authenticate(reason: reason)
        if ok { lastFillAuthentication = now() }
        return ok
    }

    /// True if a fill session is active, otherwise prompts once. Concurrent callers share one prompt.
    public func ensureFillSession(reason: String) async -> Bool {
        if isFillSessionActive { return true }
        if let inFlight { return await inFlight.value }
        let authenticator = self.authenticator
        let task = Task { await authenticator.authenticate(reason: reason) }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        if ok { lastFillAuthentication = now() }
        return ok
    }

    public var isFillSessionActive: Bool {
        guard let last = lastFillAuthentication, fillSessionDuration > 0 else { return false }
        return now().timeIntervalSince(last) < fillSessionDuration
    }

    /// Ends the fill session (e.g. on screen lock / sleep / "Lock passwords" menu item).
    public func lock() {
        lastFillAuthentication = nil
    }
}
