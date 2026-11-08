# Research: sidebar-browser UX (2026-11-07)

Context: Arc went into maintenance in May 2025 and shuts down 2026-12-22 (Atlassian acquisition). Reasons Arc gave: a "novelty tax" (too much to learn), low feature use (5.5% used more than one Space, 4% Live Folders), and a bloated codebase. Arc used 2–3× Safari's memory. Firefox, Edge, Orion and Vivaldi now ship vertical tabs; Zen is the open-source Arc successor.

## Patterns to include (ranked)
1. Vertical tab sidebar: collapses to icons, hover-expand, keyboard toggle (also in fullscreen).
2. Command bar as the primary entry point.
3. Three tab tiers: favorites grid, pinned, temporary. Keep it legible; pinned/favorites shouldn't force-load.
4. Auto-archive of stale tabs with a user-set timer (default generous, e.g. 24h/7d) and an easy-to-find archive.
5. Peek overlay for links, promotable to a tab or split in one step; never traps input (confirm before discarding typed text).
6. Quick window for links from other apps, with an off switch.
7. Stable, resizable split view (2–4 panes, drag to set up). Polish over features.
8. Spaces/profiles with a tint identity. Optional and suggested later, not in onboarding.
9. URL + security indicator always visible in compact form; copy URL with Cmd+Shift+C.
10. Rounded, inset content card with minimal chrome.
11. Light native materials (Liquid Glass) plus a density setting.
12. One-click import (Arc, Chrome, Safari) and a two-minute first run teaching the tiers and the command bar. **Arc refugees are a real audience right now.**
13. Tab sleeping, energy budget, and a resource view.
14. On-demand, context-aware AI (optional; assistive, not agentic) — out of scope for v1.

## Anti-patterns
- Too many new ideas at once; ship a small core, let advanced features be discovered later.
- Hiding content with no recovery path.
- Behavior changes on by default that can't be found in settings.
- A slow, resource-hungry shell.
- Data lock-in; commit to open export and local-first storage.

## Differentiators
1. Tab lifetimes based on intent; the archive is searchable memory with summaries.
2. Per-tab/space resource and energy cost visible in the sidebar; one-click "freeze this space".
3. Progressive disclosure: suggest a second space or split view when usage shows the need.
