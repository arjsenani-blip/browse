import AppKit
import QuartzCore
import BrowserCore
import ChromeUI

/// Debug benchmark: `Aegis --snapshot x.png --swipe-benchmark`. Drives the
/// sidebar's swipe frame by frame on the display clock (a simulated finger,
/// eased like a real flick), then a keyboard switch, and reports frame
/// intervals and the main-thread time each frame cost.
@MainActor
final class SwipeBenchmark: NSObject {
    private let controller: BrowserWindowController
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var work: [Double] = []
    private var phase = 0
    private let done: () -> Void
    private let duration = 0.42

    init(controller: BrowserWindowController, done: @escaping () -> Void) {
        self.controller = controller
        self.done = done
    }

    func run() {
        guard controller.debugSidebar.debugSwipeBegin() else { print("SWIPEBENCH need ≥2 spaces"); done(); return }
        let link = controller.debugSidebar.view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if start == 0 { start = now; last = now }
        intervals.append((now - last) * 1000)
        last = now
        let t0 = CACurrentMediaTime()
        let p = min(1, (now - start) / duration)
        let eased = 1 - pow(1 - p, 3)              // decelerating, like a flick settling
        let sign: CGFloat = phase == 0 ? -1 : 1    // swipe left (to next), then back
        controller.debugSidebar.debugSwipe(amount: sign * CGFloat(eased))
        if p >= 1 {
            controller.debugSidebar.debugSwipeEnd(amount: sign)
            report("swipe \(phase == 0 ? "→ next" : "← back")")
            phase += 1
            if phase < 2, controller.debugSidebar.debugSwipeBegin() {
                start = 0; intervals = []; work = []
            } else {
                link.invalidate()
                // A keyboard switch (spring + background fade), measured by sampling.
                measureKeyboardSwitch()
                return
            }
        }
        work.append((CACurrentMediaTime() - t0) * 1000)
    }

    private func measureKeyboardSwitch() {
        intervals = []; work = []; start = 0
        let link = controller.debugSidebar.view.displayLink(target: self, selector: #selector(sample(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        let t0 = CACurrentMediaTime()
        controller.switchSpace(1)
        print(String(format: "SWIPEBENCH keyboard switch main-thread cost %.1f ms", (CACurrentMediaTime() - t0) * 1000))
    }

    @objc private func sample(_ link: CADisplayLink) {
        let now = link.timestamp
        if start == 0 { start = now; last = now }
        intervals.append((now - last) * 1000)
        last = now
        if now - start > 0.5 {
            link.invalidate()
            report("keyboard switch (spring)")
            done()
        }
    }

    private func report(_ label: String) {
        let frames = intervals.dropFirst()
        guard !frames.isEmpty else { return }
        let target = 1000.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let hitches = frames.filter { $0 > target * 1.5 }.count
        let avgWork = work.isEmpty ? 0 : work.reduce(0, +) / Double(work.count)
        print(String(format: "SWIPEBENCH %@: %d frames, target %.1f ms, avg %.2f ms, max %.1f ms, hitches %d, main-thread/frame avg %.2f ms max %.2f ms",
                     label, frames.count, target, frames.reduce(0, +) / Double(frames.count), frames.max() ?? 0, hitches, avgWork, work.max() ?? 0))
        fflush(stdout)
    }
}
