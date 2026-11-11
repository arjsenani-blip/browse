# QA round 1: joint priority list (Rigor × Taste, 2026-11-10)

Two agents tested independently, one for function, performance and battery ("Rigor"), one for design and UX using stageshow ("Taste"). Each then argued over the other's findings.

| # | Finding | Source | Status |
|---|---|---|---|
| 1 | Session wiped on a locked-screen launch (file protection + nil-on-error) | R1 | done (no protection, set-aside + rolling prev copy) |
| 2 | Private windows not isolated (shared space, ⇧⌘T → history, downloads persisted) | R2 | done (per-window spaces; private never listed, saved, reopened or kept) |
| 3 | Gesture-less cross-origin iframe downloads, re-run on restore | R3 | done (subframes can't download) |
| 4 | No popup blocker | R5 | done (javaScriptCanOpenWindowsAutomatically = false) |
| 5 | Parameter stripping turns POST into GET | R4 | done (GET link/other only) |
| 6 | Crashed background tabs reload instantly (battery, jetsam loop) | R6 | done (background sleeps; foreground ≤3 reloads/min) |
| 7 | No first run / Arc import entry; empty state under the palette | T1, T8 | done (import card in empty palette; empty state hides) |
| 8 | App-modal JS alerts freeze the app | R10 | done (window sheets; background suppressed; loop silencing) |
| 9 | History double-counts each load (frecency skew) | R7 | done (commit records, finish updates title) |
| 10 | Space switcher dots unreadable → gradient chips | T5 | done (gradient chips + icons) |
| 11 | Favorites 4-up, Pinned/Today boundaries, Clear Today | T6 | done (4-up 44 pt, live dot, Today Clear) |
| 12 | Middle-click → new tab | R11 | done |
| 13 | Favicon plates on dark themes; shield honest on the HTTPS-only interstitial | T4, R11 | done (plates; shield secure only for real HTTPS) |
| 14 | Deleted spaces leave website data on disk | R8 | done (WKWebsiteDataStore.remove) |
| 15 | Now-playing artwork and track title | T7 | done (Media Session artwork, title, artist) |

Below the line: reader toolbar, settings voids, fingerprint toString, new-window cascade, http password warning, about:blank on failed upgrade, delight ideas (live favorites, freeze-space chip, blocked-count badge, time-of-day themes, Jump-back-in grid).
