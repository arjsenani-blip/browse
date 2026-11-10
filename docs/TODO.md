# Aegis — status of requested fixes (updated 2026-11-10)

Done:
- Crashes: window.open / target=_blank aborted the app (createNewPage configuration mismatch); favicon URL force unwrap.
- Space switching rebuilt Arc-style: live per-space page strip. The drag is a sublayer translation (<0.5 ms per frame); the release is a velocity-matched render-server spring (response 0.24); keyboard and dot switches use the same spring. 0 dropped frames at 120 Hz (scripts: `--swipe-benchmark`).
- Themes: per-space gradient frame + grain, presets, automatic light or dark text; Settings → Spaces gradient editor.
- Settings: full dashboard window (8 panes) with an appearance live preview.
- Fullscreen footer cutoff (safe area); extension buttons inside the URL pill.
- ⌘T palette centered with a faint background blur and a drop shadow.
- Battery: fixed an idle busy loop (66–90% CPU → ~0–0.5%); change-driven session saves; timer tolerance.

Next: work through docs/qa-round1.md. Start with #2 (private-window isolation: per-window spaceID, hide ephemeral spaces from normal windows, no closed/reopen or download persistence for private, tear down on close), then #6, #7–#15.
Rigor's QA harness (--qa commands, AEGIS_QA_SUPPORT isolated data dir) is in the scratchpad copy qa-rigor/aegis-qa/Sources/AegisApp/QAHarness.swift. It's worth adopting.

Ideas not yet done:
- Onboarding / first run for Arc users (import, spaces, swipe hint).
- Split view, link peek.
