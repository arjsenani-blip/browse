import AuthenticationServices
import Foundation
import Security

/// Passkey (WebAuthn) support for Vane via iCloud Keychain.
///
/// Requires the managed entitlement `com.apple.developer.web-browser.public-key-credential`
/// (requested from Apple; macOS 13.3+). Once the app is signed with it, **WebKit handles
/// `navigator.credentials.create()/get()` natively inside `WKWebView`** — there is no
/// per-request bridging to do. This type only covers the browser-level pieces:
/// detecting the entitlement, asking the user to allow Vane to use passkeys
/// (`requestAuthorizationForPublicKeyCredentials`), and listing platform credentials for
/// conditional-UI style suggestions.
///
/// Without the entitlement (ad-hoc / dev builds) `navigator.credentials` fails in the page with
/// ASAuthorizationError 1004; we report `.unavailableNoEntitlement` and never call into the
/// manager, so nothing crashes or prompts.
public final class PasskeyAuthorization: Sendable {
    public static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    public enum Status: String, Sendable, Equatable {
        case unavailableNoEntitlement
        case notDetermined
        case denied
        case authorized
    }

    /// A passkey known to the platform authenticator for a relying party (no secrets).
    public struct PlatformPasskey: Sendable, Hashable {
        public var name: String
        public var customTitle: String?
        public var relyingParty: String
        public var credentialID: Data
        public var userHandle: Data
        public var providerName: String
    }

    private let manager: ASAuthorizationWebBrowserPublicKeyCredentialManager?

    public init() {
        manager = Self.isEntitlementLikelyPresent ? ASAuthorizationWebBrowserPublicKeyCredentialManager() : nil
    }

    /// Reads our own code signature's entitlements. Ad-hoc signed builds return false.
    /// "Likely" because a present entitlement can still be rejected if the provisioning
    /// profile does not authorize it (the app would then fail to launch under AMFI).
    public static var isEntitlementLikelyPresent: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, &error)
        error?.release()
        return (value as? Bool) == true
    }

    /// Current state without prompting.
    public var authorizationState: Status {
        guard let manager else { return .unavailableNoEntitlement }
        return Self.map(manager.authorizationStateForPlatformCredentials)
    }

    /// Prompts the user (once; the system remembers the answer) to let Vane use passkeys.
    /// Returns immediately with the current state if already determined.
    public func requestAuthorization() async -> Status {
        guard let manager else { return .unavailableNoEntitlement }
        let current = Self.map(manager.authorizationStateForPlatformCredentials)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { (cont: CheckedContinuation<Status, Never>) in
            manager.requestAuthorizationForPublicKeyCredentials { state in
                cont.resume(returning: Self.map(state))
            }
        }
    }

    /// Whether the device has iCloud Keychain passkeys set up. Needs macOS 26.2+;
    /// returns nil when the OS cannot tell us.
    public var isDeviceConfiguredForPasskeys: Bool? {
        if #available(macOS 26.2, *) {
            return ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
        }
        return nil
    }

    /// Passkeys saved for `relyingParty` (e.g. "github.com"). Empty unless authorized.
    public func platformCredentials(forRelyingParty relyingParty: String) async -> [PlatformPasskey] {
        guard let manager, authorizationState == .authorized else { return [] }
        let creds = await manager.platformCredentials(forRelyingParty: relyingParty)
        return creds.map {
            PlatformPasskey(
                name: $0.name,
                customTitle: $0.customTitle,
                relyingParty: $0.relyingParty,
                credentialID: $0.credentialID,
                userHandle: $0.userHandle,
                providerName: $0.providerName
            )
        }
    }

    private static func map(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> Status {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
