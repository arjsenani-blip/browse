# QA round 1: joint priority list (Rigor × Taste, 2026-11-10)

Two agents tested independently, one for function, performance and battery ("Rigor"), one for design and UX using stageshow ("Taste"). Each then argued over the other's findings.

| # | Finding | Source | Status |
|---|---|---|---|
| 1 | Session wiped on a locked-screen launch (file protection + nil-on-error) | R1 | done (no protection, set-aside + rolling prev copy) |
| 2 | Private windows not isolated (shared space, ⇧⌘T → history, downloads persisted) | R2 | todo |
| 3 | Gesture-less cross-origin iframe downloads, re-run on restore | R3 | done (subframes can't download) |
| 4 | No popup blocker | R5 | done (javaScriptCanOpenWindowsAutomatically = false) |
| 5 | Parameter stripping turns POST into GET | R4 | done (GET link/other only) |
| 6 | Crashed background tabs reload instantly (battery, jetsam loop) | R6 | todo |
| 7 | No first run / Arc import entry; empty state under the palette | T1, T8 | todo |
| 8 | App-modal JS alerts freeze the app | R10 | todo |
| 9 | History double-counts each load (frecency skew) | R7 | todo |
| 10 | Space switcher dots unreadable → gradient chips | T5 | todo |
| 11 | Favorites 4-up, Pinned/Today boundaries, Clear Today | T6 | todo |
| 12 | Middle-click → new tab | R11 | todo |
| 13 | Favicon plates on dark themes; shield honest on the HTTPS-only interstitial | T4, R11 | todo |
| 14 | Deleted spaces leave website data on disk | R8 | todo |
| 15 | Now-playing artwork and track title | T7 | todo |

Below the line: reader toolbar, settings voids, fingerprint toString, new-window cascade, http password warning, about:blank on failed upgrade, delight ideas (live favorites, freeze-space chip, blocked-count badge, time-of-day themes, Jump-back-in grid).
