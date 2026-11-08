# Research: Arc-style space swipe (2026-11-08)

- Gesture: `NSEvent.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin:max:)` on the sidebar only (WKWebView keeps its own back/forward swipe). Claim it only on `.began` with precise deltas and horizontal dominance ≥1.5:1, and only when `NSEvent.isSwipeTrackingFromScrollEventsEnabled`. Otherwise fall back to manual tracking: 8 pt axis lock; commit at 30% of width or 500 pt/s; rubber band `(1 - 1/(x*0.55/w + 1)) * w`.
- The system rubber-bands at the ends and animates gestureAmount to -1/0/1 after release; follow it, and commit when `isComplete`.
- Animation: translate layers only (live sidebar plus cached bitmap snapshots of the neighbour spaces) inside `CATransaction.setDisableActions(true)`; no layout per frame. Accent and wash interpolate with |p|. Click-to-switch uses a spring: commit ζ1.0 / 0.32 s, cancel ζ0.85 / 0.28 s. Reduce Motion: 0.18 s cross-fade.
- Content: don't slide it. Swap on commit under a cached snapshot of the target space's selected tab, faded out over 0.15 s after first paint.
- Perf: no SwiftUI or blur in moving layers; `layerContentsRedrawPolicy = .never`; Instruments Animation Hitches target < 5 ms/s at 120 Hz.
Sources: TechCrunch (Arc spaces swipe), Apple docs for trackSwipeEvent / isSwipeTrackingFromScrollEventsEnabled / takeSnapshot / displayLink, zen-browser issue #7274.
