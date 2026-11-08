# Aegis

A privacy-first, keyboard-driven browser for macOS, with a sidebar of vertical tabs, spaces and a command palette. Native Swift and AppKit on the system WebKit, so it idles small and feels like a Mac app.

![Command palette](docs/design/direction-glass-light.png)

## Build and run

```sh
swift test                      # 170+ tests
scripts/bundle.sh release       # → build/Aegis.app (~7 MB, ad-hoc signed)
open build/Aegis.app
scripts/bench-memory.sh         # idle footprint vs the 150 MB budget
scripts/bench-compare.sh        # Aegis vs Chromium (Edge, throwaway profile)
```

Requires macOS 15.4+, Xcode 26+ (Swift 6).

## Faster and lighter than Chromium

Measured with the same 5 sites open (`docs/benchmarks.md`):

| | Aegis | Microsoft Edge |
|---|---|---|
| Launch to first window | **0.6 s** | 1.0–1.3 s |
| Total memory, all processes | **666–752 MB** | 1,301–1,335 MB |
| Idle app process | **40 MB** | n/a |

## What works today (verified on this Mac, 2026-11-08)

| Area | Status | Evidence |
|---|---|---|
| Sidebar: favorites grid, pinned, Today, sleeping tabs, spaces | ✅ | Light and dark screenshots |
| Command palette (⌘K / ⌘T / ⌘L): tabs, history, favorites, commands, inline completion | ✅ | fzf V2 port; 20k candidates in 3–6 ms (release) |
| Local history: SQLite, frecency, FTS5 | ✅ | 23 tests |
| Ad and tracker blocking: EasyList + EasyPrivacy → 119,970 WebKit rules | ✅ | The Verge: third-party hosts went from 42 to 11, with no doubleclick, Amazon ads, Criteo, GTM or Facebook |
| Blocking from the first request at launch | ✅ | Compiled lists looked up by ID before tabs restore |
| Cosmetic filtering, tracking-parameter stripping | ✅ | Tests |
| Fingerprinting defenses (canvas/audio/WebGL noise, normalized hardware hints) | ✅ | Canvas hash stable within a site, different across sites and sessions |
| Tab hibernation (idle, memory pressure, manual) | ✅ | WebKit memory went from 751 MB to 300 MB when 4 of 5 tabs slept |
| App process memory | ✅ | 40 MB idle; 54–57 MB with 5 sites (budget 150 MB) |
| Spaces with separate cookies and logins | ✅ | httpbin: a cookie set in one space is absent in another |
| Two-finger swipe between spaces (interactive, rubber-band, accent cross-fade) | ✅ Built; needs a real trackpad to try | `trackSwipeEvent`, research in `docs/research/07-space-swipe.md` |
| Rename / recolor / delete spaces (right-click the space name, or ⌘K) | ✅ | |
| Library: downloads and media (⌥⌘J, or the tray button) | ✅ | Real downloads listed; media grid with thumbnails |
| Now playing: background audio/video mini player with play/pause and PiP | ✅ | Background track detected and controllable |
| Private windows (non-persistent, never saved, no history) | ✅ | |
| Reader mode (Readability + DOMPurify, script-free view with CSP) | ✅ | Screenshot |
| Find on page, downloads, session restore, archive of stale tabs | ✅ | |
| Password manager (Keychain), CSV import/export from Passwords, Safari, Chrome | ✅ | Real-Keychain round trip |
| Autofill banner (fill / save / update) | ✅ | Live login form: detected, submitted, offered to save in < 1 ms |
| Passkeys from iCloud Keychain | ⏳ Code ready; needs Apple's entitlement | See below |
| DNS-over-HTTPS (Quad9 by default; Cloudflare, Mullvad) | ✅ | Connection reports show `dnsProtocol=https`; pages load through the proxy |
| Import from Arc (spaces, favorites, pinned), Chromium browsers, Safari | ✅ Tested on sample files | Arc isn't installed here, so it hasn't been tried on real Arc data |
| Chrome Web Store extensions | 🔧 In progress | |

## Apple Passwords: what's possible

- **Passkeys (iCloud Keychain):** these work once Apple grants the `com.apple.developer.web-browser.public-key-credential` entitlement. Only the Account Holder of a paid Apple Developer organization can request it, at https://developer.apple.com/contact/request/macos-browsers-passkeys/. After approval, sign with Developer ID plus the provisioning profile, and WebKit handles WebAuthn natively. The Settings window shows the current status.
- **Saved iCloud Keychain passwords:** Apple offers no API for third-party browsers to read or write them. Chrome and Arc only get them through Apple's extension, which Apple allow-lists per browser. Aegis keeps its own passwords in the macOS Keychain instead, and imports them from the Passwords app (File → Import Passwords).
- **Verification codes from Messages and Mail:** macOS fills these system-wide. This hasn't been checked on a live site yet.

## Architecture

See `CLAUDE.md` for the module map and rules. Every decision is backed by a research note in `docs/research/`.

## Known limits

- WebKit can't intercept http/https requests, so blocking is declarative. 696 of 134k filters, such as procedural cosmetics and scriptlets, can't be expressed.
- Fingerprint defenses run in the page world and can be detected by scripts like CreepJS.
- Sites behave as they do in Safari, quirks included.
- Ad-hoc builds change their code signature on every rebuild, so macOS may ask again for Keychain access.

## Licenses

Readability (Apache-2.0), DOMPurify (Apache-2.0/MPL-2.0), and EasyList/EasyPrivacy (GPLv3 / CC BY-SA 3.0, shipped as data). See `Sources/ContentBlocking/Resources/lists/LICENSE-filter-lists.txt`.
