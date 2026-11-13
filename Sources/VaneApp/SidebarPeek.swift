import AppKit
import ChromeUI

/// While the sidebar is hidden: a thin strip at the window's left edge. Resting the pointer on it
/// for a moment slides the sidebar in over the page as a floating panel (traffic lights back);
/// it slides away shortly after the pointer leaves. The panel's sidebar button docks it again.
@MainActor
final class SidebarPeek {
    private unowned let controller: BrowserWindowController
    private let edge = PeekEdgeView()
    private let panel = PeekPanelView()
    private let background = ThemeBackgroundView()
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private(set) var isShown = false
    private var installed = false

    init(controller: BrowserWindowController) {
        self.controller = controller
        edge.onEnter = { [weak self] in self?.scheduleShow() }
        edge.onExit = { [weak self] in self?.showWork?.cancel() }
        panel.onEnter = { [weak self] in self?.hideWork?.cancel() }
        panel.onExit = { [weak self] in self?.scheduleHide() }
    }

    private func install() {
        guard !installed, let root = controller.window?.contentView else { return }
        installed = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(edge)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 6),
        ])
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.shadow = NSShadow()
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.28
        shadowHost.layer?.shadowRadius = 22
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -8)
        for v in [background, controller.peekSidebar.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: panel.leadingAnchor), v.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                v.topAnchor.constraint(equalTo: panel.topAnchor), v.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
        }
        panel.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(panel)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.isHidden = true
        root.addSubview(shadowHost, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor), panel.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            panel.topAnchor.constraint(equalTo: shadowHost.topAnchor), panel.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            shadowHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            shadowHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            shadowHost.widthAnchor.constraint(equalToConstant: Tokens.Size.sidebarDefault),
        ])
    }

    private var host: NSView? { panel.superview }

    func setEnabled(_ enabled: Bool) {
        if enabled { install() }
        edge.isHidden = !enabled
        if !enabled { hide(animated: false) }
    }

    private func scheduleShow() {
        hideWork?.cancel()
        guard !isShown else { return }
        let work = DispatchWorkItem { [weak self] in self?.show() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func show() {
        guard let host, !isShown else { return }
        isShown = true
        background.set(themes: [controller.windowSpace.resolvedTheme], current: 0, keepingAnimation: false)
        controller.refresh()
        controller.setTrafficLightsHidden(false)
        host.isHidden = false
        host.superview?.addSubview(host, positioned: .above, relativeTo: nil)   // stay above toasts and the palette scrim
        let offset = -(Tokens.Size.sidebarDefault + 30)
        host.layer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
        guard !Tokens.Motion.reduceMotion else { host.layer?.transform = CATransform3DIdentity; return }
        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.fromValue = offset
        slide.toValue = 0
        slide.mass = 1; slide.stiffness = 420; slide.damping = 36
        slide.duration = slide.settlingDuration
        host.layer?.add(slide, forKey: "peek")
        host.layer?.transform = CATransform3DIdentity
    }

    func hide(animated: Bool) {
        showWork?.cancel(); hideWork?.cancel()
        guard let host, isShown else { return }
        isShown = false
        if controller.sidebarHidden { controller.setTrafficLightsHidden(true) }
        let offset = -(Tokens.Size.sidebarDefault + 30)
        guard animated, !Tokens.Motion.reduceMotion else { host.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak host] in
            MainActor.assumeIsolated { if self?.isShown == false { host?.isHidden = true } }
        }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = offset
        slide.duration = 0.18
        slide.timingFunction = CAMediaTimingFunction(name: .easeIn)
        host.layer?.add(slide, forKey: "peek")
        host.layer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
    }
}

/// Reports the pointer entering and leaving.
class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

final class PeekEdgeView: HoverView {
    // Invisible; clicks fall through to the page except in the strip itself.
}

final class PeekPanelView: HoverView {}
