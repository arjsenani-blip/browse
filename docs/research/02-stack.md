# Research: stack & engine (2026-11-07)

## Decision: native Swift 6 + AppKit shell (SwiftUI for leaf views) on stock WKWebView, macOS 15.4+
- **Memory:** the native chrome has no extra WebContent renderer for the UI. Tauri/Electron render the chrome as web content. Hopp's test: Chromium renderers use ~2× WKWebView. Better Stack: Tauri ~109 MB vs Electron ~128 MB idle. The 150 MB budget applies to the app process; the WebKit process tree is measured separately.
- **Platform features need native code anyway:** `WKWebsiteDataStore(forIdentifier:)` (macOS 14+), `WKWebExtension`/`WKWebExtensionController` (macOS 15.4+), passkey entitlement, AuthenticationServices, Keychain.
- **Hibernation precedent:** DDG `UnloadedTab.swift` + `TabLazyLoader`: keep title, favicon, `interactionStateData`; drop the WKWebView so its WebContent process exits; rebuild on select.
- **Prior art:** duckduckgo/apple-browsers (Apache-2.0, verified; Duck Sans font excluded): AppKit + WKWebView, ~30 local SwiftPM packages, extension host, `MemoryUsageMonitor.swift`. Lift patterns, and code with attribution.
- **Weakness:** no http/https interception (`WKURLSchemeHandler` handles custom schemes only); `WKContentRuleList` is declarative and gives no feedback on what it blocked. Fine for privacy blocking; no header rewriting.
- **Runner-up:** CEF/Chromium in a Swift shell (Arc's approach). Full MV3 and webRequest, but a 200 MB+ framework, an idle baseline over budget, and weekly security patching.
- **Rejected:** Tauri 2 (child webviews still `unstable`, overlay and keyboard gaps, Apple APIs need objc2 anyway); Electron.

## Layout (SwiftPM monorepo)
```
App/ (thin target; Info.plist, entitlements)
Packages/
  BrowserCore/ WebEngine/ ContentBlocking/ Extensions/ Credentials/
  SidebarUI/ CommandPalette/ Persistence/ Telemetry/(local only)
Tests/ UITests/ scripts/ (bundle.sh, sign.sh, bench-memory.sh)
```

## Tooling
`swift build`/`swift test` with Swift Testing and Swift 6 strict concurrency. Build an executableTarget, and have `scripts/bundle.sh` assemble the .app and run `codesign`. Full Xcode is needed for provisioning profiles, XCUITest and Instruments (it's installed). Memory benchmark: `footprint` / `vmmap --summary` on the app process; fail above 150 MB idle.

## Risks
Passkey entitlement approval; incomplete WKWebExtension coverage (feature-flag it); no request interception; Safari site quirks.
