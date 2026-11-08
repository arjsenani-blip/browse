---
name: aegis-next-tasks
description: "Open user-requested fixes for the Aegis browser (2026-11-08), not yet started — space-swipe smoothness, real settings dashboard, fullscreen cutoff, extensions in URL bar, adversarial test agents"
metadata:
  node_type: memory
  type: project
  originSessionId: b3ef3beb-8a3a-466a-b0ac-34a708088a6c
  modified: 2026-11-08T13:31:03.018Z
---

The user asked for these on 2026-11-08 after testing `/Applications/Aegis.app` (the project is `~/Projects/aegis-browser`; see [[browser-project]]). None were started because usage ran out. Mirrored in the repo at `docs/TODO.md`.

1. **Space switch animation is choppy.** Make it as smooth as Arc. Run a test agent to observe it first. Code: `Sources/ChromeUI/Sidebar.swift` (`trackSwipe`, `setSwipeOffset`, `slideIn`, `cacheCurrentSpaceSnapshot`). Suspects:
   - `cacheDisplay` snapshot taken synchronously at gesture start;
   - `apply()` doing a full sidebar rebuild and `reloadData` on commit;
   - neighbor panes as NSImageView rather than CALayer contents;
   - wash recolor per frame;
   - `slideIn` racing with the store refresh.
   Spec: `docs/research/07-space-swipe.md` (translate layers only, pre-snapshot, spring ζ1.0 / 0.32 s).
2. **Settings shows nothing.** `Sources/AegisApp/SettingsWindow.swift` (SwiftUI Form in NSHostingController) appears empty. Replace it with a designed dashboard window (sidebar sections), not a bare system panel. It needs:
   - full theme customization: accent per space, light/dark/auto, sidebar tint/opacity, density, corner radius, font size;
   - Spaces management: list, add, rename, color, delete, profile isolation;
   - privacy, DoH resolver, tabs, passwords, extensions list.
   Design the mockup first with the `stageshow` skill (benjitaylor), at `design/stageshow/examples/aegis-*`.
3. **Downloads/Library button cut off in fullscreen,** bottom-right of the sidebar footer. See the footer constraints in `Sidebar.swift` `loadView` (`footer.bottomAnchor -12`). Likely a safe-area / fullscreen toolbar inset issue.
4. **Pinned extension buttons belong in the URL bar,** inside the URL pill, not in a row below it. See `setExtensionButtons` in `Sidebar.swift`, `URLPill`, and `TopTabBar`.
5. **Run 2 adversarial QA agents** that test every feature from different angles, argue with each other, and iterate to polish. Use the stageshow skill for design critique. Tools: the debug harness `Aegis --snapshot out.png --open … --eval … --palette … --library` (`DebugSnapshot.swift`); the screen can't be captured from outside without permission.

**Why:** the user is dogfooding and found these rough edges.
**How to apply:** start with 2 and 3 (cheap, visible), then 1, then 4, then the QA agents. Rebuild and install with `scripts/install.sh`. Commit locally and don't push.

6. **⌘T palette:** center in the window and faintly blur the app behind it. Done 2026-11-08 (NSVisualEffectView scrim at 0.55 alpha, centered). Tune if it looks too strong.
