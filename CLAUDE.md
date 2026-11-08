# Aegis Browser

A privacy-first, keyboard-driven macOS browser with an original sidebar design (vertical tabs, spaces, command palette). Research behind every decision is in `docs/research/`; the design direction is in `docs/design/` (built with the `stageshow` skill, sources in `design/stageshow/examples/aegis-*`).

## Stack (decided, see docs/research/02-stack.md)
- Swift 6 (strict concurrency), AppKit shell, SwiftUI only for leaf views (palette, settings, onboarding). Stock `WKWebView`. Deployment target **macOS 15.4**.
- SwiftPM is the source of truth. No checked-in `.xcodeproj`.
- No third-party Swift dependencies unless a module's spec says so. SQLite via the system `SQLite3` module.
- Bundled JS (Readability, DOMPurify) lives in `Sources/*/Resources/js/`, with licenses in `ThirdPartyNotices.md`.

## Layout
```
Package.swift
Sources/
  AegisApp/          executable: AppDelegate, menus, window controller, wiring
  BrowserCore/       models: Tab, Space, Profile; session store; hibernation policy (pure Swift, unit-tested)
  WebEngine/         WKWebView factory, per-profile WKWebsiteDataStore, navigation policy, hibernation executor
  ContentBlocking/   filter lists -> WKContentRuleList compile/cache, cosmetic scripts, tracking-param stripping
  Persistence/       SQLite wrapper, history + frecency + FTS5, bookmarks, encrypted-at-rest key handling
  Search/            fuzzy matcher (fzf V2 port), omnibox ranking
  Credentials/       Keychain password store, passkey authorization (entitlement-gated)
  ChromeUI/          sidebar (tabs, swipe between spaces, now playing), top tab bar, palette (SwiftUI), library, reader, tokens
  WebEngine/Extensions/  Chrome Web Store install (CRX verify/unpack), WKWebExtension host, tab/window adapters
Tests/<Module>Tests/ Swift Testing
scripts/             bundle.sh (assemble + codesign .app), bench-memory.sh, update-filters.sh
```

## Build & test
- `swift build` / `swift test` — must stay green.
- `scripts/bundle.sh [debug|release]` → `build/Aegis.app` (ad-hoc signed). Run with `open build/Aegis.app`.
- `scripts/bench-memory.sh` → idle footprint of the app process after launch + 10 s. **Budget: < 150 MB app process idle** (WebKit child processes reported separately).

## Rules
- **Zero telemetry.** The only network requests the app itself makes: filter-list updates (easylist.to, secure.fanboy.co.uk), DoH lookups to the chosen resolver, site favicons, and `clients2.google.com` / `clients2.googleusercontent.com` **only when the user installs an extension**. No analytics, no remote search suggestions unless the user opts in.
- Glass (`NSGlassEffectView` / visual effect) only on sidebar, palette, HUDs — never on tab rows or page content. Respect Reduce Transparency / Reduce Motion / Increase Contrast.
- Design tokens in `ChromeUI/Tokens.swift` match `docs/research/05-design-language.md`; don't hard-code window radii.
- Anything requiring a restricted entitlement (passkeys) is behind a runtime availability check and degrades gracefully in ad-hoc builds.
- Keep hot paths (palette keystroke → results) under 16 ms; ranking work off the main thread except the in-memory pass.
- Commit locally per phase with descriptive messages; never push without the user asking.

## Known platform limits (don't fight them)
- iCloud Keychain passwords are not available to third-party browsers → own Keychain-backed manager + CSV import.
- No http/https request interception in WKWebView → blocking is declarative (`WKContentRuleList`, 150k rules/list).
- DoH goes through the in-app CONNECT proxy (`EncryptedDNSProxy`) set via `WKWebsiteDataStore.proxyConfigurations`; no HTTP/3 under a proxy, WebRTC UDP bypasses it.
- Extensions: WKWebExtension supports MV3 + declarativeNetRequest; no blocking webRequest, offscreen, sidePanel, identity, native messaging. Extensions are off in private windows unless granted.
- Debug harness: `Aegis --snapshot out.png [--open URLs] [--eval JS] [--palette q] [--library] …` (see DebugSnapshot.swift) renders windows without screen-recording permission.
