# Aegis — status of requested fixes (updated 2026-11-10)

Done:
- Crashes: window.open / target=_blank aborted the app (createNewPage configuration mismatch); favicon URL force unwrap.
- Space switching rebuilt Arc-style: live per-space page strip. The drag is a sublayer translation (<0.5 ms per frame); the release is a velocity-matched render-server spring (response 0.24); keyboard and dot switches use the same spring. 0 dropped frames at 120 Hz (scripts: `--swipe-benchmark`).
- Themes: per-space gradient frame + grain, presets, automatic light or dark text; Settings → Spaces gradient editor.
- Settings: full dashboard window (8 panes) with an appearance live preview.
- Fullscreen footer cutoff (safe area); extension buttons inside the URL pill.
- ⌘T palette centered with a faint background blur and a drop shadow.
- Battery: fixed an idle busy loop (66–90% CPU → ~0–0.5%); change-driven session saves; timer tolerance.

In progress:
- Two adversarial QA agents (function/perf "Rigor", design "Taste" using stageshow) → debate → fix list.

Ideas not yet done:
- Onboarding / first run for Arc users (import, spaces, swipe hint).
- Split view, link peek.
