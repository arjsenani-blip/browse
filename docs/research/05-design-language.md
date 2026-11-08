# Research: macOS 26/27 design language for the browser chrome (2026-11-07)

## Platform rules
- Liquid Glass is for navigation and controls only, never for content. The sidebar split item gets glass automatically; remove legacy NSVisualEffectView. Group nearby glass in `NSGlassEffectContainerView` / `GlassEffectContainer` (glass can't sample glass). Morphing (`glassEffectID`) is SwiftUI-only.
- Never hard-code the window radius or control heights; use `layoutGuide(for: .safeArea(cornerAdaptation:))` / ConcentricRectangle. macOS 27: uniform corner radius, edge-to-edge sidebars, a system transparency slider; opting out of glass is reportedly not possible. The chrome must work fully clear AND fully tinted.
- Accessibility: Reduce Transparency, Tinted glass (26.1), Increase Contrast. Glass costs GPU, so keep it off scrolling surfaces and never animate it continuously.

## Tokens
- Radii: window = system; content card concentric (~10–12pt fallback); tab row 8; control 6; palette/popover 16–20.
- Spacing: 4pt base (2,4,6,8,12,16,20,24,32). Card inset 8pt top/right/bottom, 0 at the sidebar edge (6 if the sidebar floats). Sidebar: 10pt horizontal padding, 2pt tab gap, 16pt section gap.
- Sidebar rows follow `sidebarRowSize`: S 24/16/11, M 28/20/13, L 32/24/15 (row height/icon/text size in pt).
- Type: tab 13pt Regular (Medium when selected); section header 11pt Semibold, secondary color; URL 13pt; meta 11pt.
- Materials: glass `.regular` on sidebar, toolbar items, URL/palette, find bar, HUDs. No glass on tab rows, the content card or lists. Selected tab = space accent at 12–16% (22% with Increase Contrast). Card = opaque, 0.5pt separator hairline, shadow y1 blur3 ~10%.
- Per-space accent hue drives the selected fill, space icon, prominent button tint, and a 4–8% sidebar wash. Semantic system colors elsewhere. Selected text contrast ≥4.5:1.
- Motion: select 0.25s/bounce 0; reorder snappy 0.3/0.15; sidebar toggle smooth 0.35; space switch 0.4/0.1 slide + tint cross-fade; palette glass morph. Reduce Motion → 0.15s fades. SF Symbols 7 draw-on for loading/audio, variable draw for downloads.

## Framework split
- **AppKit:** NSWindow, NSSplitViewController, NSToolbar, WKWebView hosting, the **tab sidebar as a view-based NSOutlineView** (reuse, drag/drop, animated moves). SwiftUI List regresses at scale; The Browser Company moved Arc's Mac app to AppKit for performance.
- **SwiftUI** (via NSHostingView): command palette/URL popover (glass morph), settings, new-tab page, onboarding, hover cards.
- One `@Observable` tab store as the source of truth; the outline view applies diffs.
