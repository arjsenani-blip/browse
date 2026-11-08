# Research: Apple Passwords integration (2026-11-07)

## Verdict
- **Passkeys (iCloud Keychain): achievable** with the managed entitlement
  `com.apple.developer.web-browser.public-key-credential` (macOS 13.3+).
  - Request: https://developer.apple.com/contact/request/macos-browsers-passkeys/ (Account Holder only; can take weeks).
  - Criteria: declare http/https schemes in Info.plist, show URL field/search/bookmarks on launch, navigate directly to requested pages.
  - With the entitlement, WKWebView handles WebAuthn natively (community report, forums thread 774904); without it `navigator.credentials` fails with ASAuthorizationError 1004.
  - Use `ASAuthorizationWebBrowserPublicKeyCredentialManager` for `requestAuthorizationForPublicKeyCredentials`, `authorizationStateForPlatformCredentials`, `platformCredentials(forRelyingParty:)` (conditional UI), `isDeviceConfiguredForPasskeys`.
  - Chrome uses this path since v118. Orion does not support iCloud passkeys.
  - Risk: 15.4.x regression broke approved apps; QA every OS release.
- **iCloud Keychain passwords: no public API for browsers.**
  - SecRequestSharedWebCredential is deprecated (and was own-domain only). ASAuthorizationPasswordProvider is own-domain only. ASCredentialProviderViewController is the provider side.
  - The iCloud Passwords Chrome extension talks over native messaging to `PasswordManagerBrowserExtensionHelper`, which checks an Apple-maintained bundle-ID allowlist. That needs Chrome-extension support and Apple listing us. Not realistic for a WKWebView browser now.
  - Fallback: our own Keychain-backed password manager, CSV import from the Passwords app, an "Open in Passwords" deep link, and save/fill UI.
- **Verification codes:** macOS 26 Security Code AutoFill works in all text-accepting apps; WebKit maps `autocomplete="one-time-code"`, so WKWebView should get it free (verify).
- **Distribution:** paid org Developer account; Developer ID + provisioning profile + hardened runtime + notarization. Default browser needs no entitlement (`NSWorkspace.setDefaultApplication`).

## Recommendation
Native Swift/AppKit + WKWebView. Build the passkey integration behind the entitlement and apply early. Ship our own Keychain password manager with Passwords CSV import.
