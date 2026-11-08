# Research: privacy & blocking layer on WKWebView (2026-11-07)

## Blocking
- `WKContentRuleList`: max **150k rules per list**; attach several lists to one `WKUserContentController`. Allowlist (`ignore-previous-rules`) only works within its own list, so keep exceptions with the rules they override.
- Converters: AdGuard SafariConverterLib (GPL-3.0, best coverage); **brave/adblock-rust 0.12.x (MPL-2.0)** with `content-blocking` feature + per-host cosmetic engine (preferred, permissive; via FFI); DDG TrackerRadarKit (Apache-2.0, TDS tracker list).
- Cosmetic CSS → `WKUserScript` in a named `WKContentWorld`. Scriptlets must run in `.page` world at document start, all frames. Gaps: workers, some about:blank/srcdoc frames.
- Updates: fetch every 24h over HTTPS (ETag), compile off the main thread keyed by content hash, `lookUpContentRuleList` at launch, atomic swap, keep last good list.
- Tests: warm lookup ≤100 ms; cold compile ≤5 s in background; d3ward / canyoublockit pass rate ≥ Orion; top-100 median page-load regression ≤5%.

## Fingerprinting
- WebKit gives ITP + full third-party cookie blocking. Safari 26 AFP has no public WKWebView switch, so measure the defaults.
- Add Brave-style farbling seeded per session + eTLD+1 (canvas, audio, WebGL readPixels), normalize hardwareConcurrency, deviceMemory, WebGL vendor/renderer. These run in the page world and are detectable (CreepJS "lies"); keep noise tiny and stable per site.
- Tests: Cover Your Tracks (fingerprint differs across sites and sessions, stable within one), CreepJS baseline, no breakage on hCaptcha/Maps/Figma.

## DoH
- Network.framework privacy context is not reliably honored by WKWebView (out-of-process networking).
- **Recommended:** in-app local proxy (`NWListener` on 127.0.0.1, auth token) set via `WKWebsiteDataStore.proxyConfigurations` (macOS 14+, HTTP CONNECT / SOCKS5). The proxy resolves with a DoH-configured `NWParameters` privacy context. Set it before the first load. Loses HTTP/3/QUIC; WebRTC UDP should be disabled or relayed.
- `NEDNSSettingsManager` is an optional system-wide mode (needs an entitlement and the user's opt-in).
- Test: pcap shows 0 packets on port 53 from WebKit networking.

## Other
- HTTPS: `upgradeKnownHostsToHTTPS` + `preferredHTTPSNavigationPolicy` (macOS 15.2+), with a fallback interstitial.
- Tracking params: strip in `decidePolicyFor navigationAction` (cancel + reload the clean URL); ClearURLs rules (LGPL) or AdGuard URL filter (GPL). Can't rewrite subresources.
- Cookie consent: DDG autoconsent (MPL-2.0) in an isolated world.
- Containers: `WKWebsiteDataStore(forIdentifier:)` per container; `.nonPersistent()` for private windows; per-store proxy + farbling seed. Test that cookies, storage, cache and HSTS stay isolated and that `remove(forIdentifier:)` wipes the files.
- Encrypted storage: SQLCipher via GRDB, 256-bit key in Keychain (`WhenUnlockedThisDeviceOnly`); CryptoKit AES-GCM for blobs. WebKit's own storage relies on FileVault.
- Zero telemetry: only list-update hosts, opt-in MetricKit crash reports. Test: an idle hour pcap shows allowlisted hosts only.

## Licensing
Stay permissive: adblock-rust (MPL) + TrackerRadarKit (Apache) + autoconsent (MPL). GPL filter lists downloaded as data, not linked.
