# Aegis — status of requested fixes (updated 2026-11-10)

Done:
- Crashes: window.open / target=_blank aborted the app (createNewPage configuration mismatch); favicon URL force unwrap.
- Space switching rebuilt Arc-style: live per-space page strip. The drag is a sublayer translation (<0.5 ms per frame); the release is a velocity-matched render-server spring (response 0.24); keyboard and dot switches use the same spring. 0 dropped frames at 120 Hz (scripts: `--swipe-benchmark`).
- Themes: per-space gradient frame + grain, presets, automatic light or dark text; Settings → Spaces gradient editor.
- Settings: full dashboard window (8 panes) with an appearance live preview.
- Fullscreen footer cutoff (safe area); extension buttons inside the URL pill.
- ⌘T palette centered with a faint background blur and a drop shadow.
- Battery: fixed an idle busy loop (66–90% CPU → ~0–0.5%); change-driven session saves; timer tolerance.

Done (QA round 1, all 15 agreed items): see docs/qa-round1.md.

Done (Checker audit): reader pill / dark-mode default / links open in the tab / ⌘± text size / lighter underlines; search-engine picker; http password warnings; about:blank never overwrites a tab's URL; private-space and folder cross-profile leaks; session restore hardening; menu shortcut fixes (⌃⇧Tab, ⌘=, ⌘G); see git log.

Next (below the line from QA):
- Reader: indicator in the URL pill.
- Settings: Tab layout card still half empty; move passkeys out of a dead tile; Arc import row under Spaces.
- Fingerprint shim: native-looking toString; noise on export only (pixel readback).
- Delight: live favorites (unread badge, hover peek), freeze-space chip showing memory freed, blocked-count on the shield, time-of-day themes.
- Run a QA round 2 (Rigor + Taste) on the new build.

Dev workflow: `scripts/bundle.sh` builds "Aegis Dev" (bundle ID app.aegis.browser.dev, data in ~/Library/Application Support/Aegis Dev) so harness runs never touch the real session. `scripts/install.sh` builds the real identity and never quits a running Aegis.
