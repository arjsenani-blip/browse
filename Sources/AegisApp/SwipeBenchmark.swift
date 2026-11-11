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
    private var settleFrames = -1
    private let done: () -> Void
    private let duration = 0.22   // finger travel before release

    init(controller: BrowserWindowController, done: @escaping () -> Void) {
        self.controller = controller
        self.done = done
    }

    func run() {
        guard controller.debugSidebar.debugSwipeBegin() else {
            print("SWIPEBENCH could not start: visible spaces \(controller.visibleSpaces.count)"); fflush(stdout); done(); return
        }
        let link = controller.debugSidebar.view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        // A covered window gets no display-link callbacks; fall back to a timer
        // that measures main-thread cost per step (frame pacing needs a visible window).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.start == 0 else { return }
            link.invalidate()
            print("SWIPEBENCH window covered: timer mode (main-thread cost only)"); fflush(stdout)
            self.timerMode = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.finished { self.timer?.invalidate(); return }
                    self.step(now: CACurrentMediaTime(), link: nil)
                }
            }
        }
    }

    private var settleStart: CFTimeInterval = 0
    private var timerMode = false
    private var timer: Timer?
    private var finished = false

    @objc private func tick(_ link: CADisplayLink) { step(now: link.timestamp, link: link) }

    private func step(now: CFTimeInterval, link: CADisplayLink?) {
        if start == 0 { start = now; last = now }
        intervals.append((now - last) * 1000)
        last = now
        let sign: CGFloat = phase == 0 ? -1 : 1    // swipe left (to next), then back
        if settleFrames >= 0 {
            // After release: the settle spring runs on the render server; watch it land.
            if now - settleStart > 0.32 {
                report("release spring \(phase == 0 ? "→ next" : "← back")")
                settleFrames = -1
                phase += 1
                if phase < 2, controller.debugSidebar.debugSwipeBegin() {
                    start = 0; intervals = []; work = []
                } else {
                    link?.invalidate()
                    if timerMode {
                        let t0 = CACurrentMediaTime()
                        controller.switchSpace(1)
                        print(String(format: "SWIPEBENCH keyboard switch main-thread cost %.2f ms", (CACurrentMediaTime() - t0) * 1000))
                        finished = true
                        fflush(stdout)
                    } else {
                        measureKeyboardSwitch()
                    }
                }
            }
            return
        }
        let t0 = CACurrentMediaTime()
        let p = min(1, (now - start) / duration)
        let travel: CGFloat = 0.6                  // let go 60% of the way, mid-flick
        controller.debugSidebar.debugSwipe(amount: sign * travel * CGFloat(p))
        work.append((CACurrentMediaTime() - t0) * 1000)
        if p >= 1 {
            report("drag \(phase == 0 ? "→ next" : "← back")")
            let r0 = CACurrentMediaTime()
            controller.debugSidebar.debugSwipeEnd(amount: sign * travel, velocity: sign * travel / CGFloat(duration))
            print(String(format: "SWIPEBENCH release main-thread cost %.2f ms", (CACurrentMediaTime() - r0) * 1000))
            settleFrames = 0
            settleStart = now
            intervals = []; work = []
        }
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
