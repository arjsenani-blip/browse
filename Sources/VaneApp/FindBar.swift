import AppKit
import WebKit

/// In-page find: a small glass HUD over the page card's top-right corner.
@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onClose: (() -> Void)?
    private weak var webView: WKWebView?
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        field.placeholderString = "Find on page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(search)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let prev = button("chevron.up", "Previous Match", #selector(previous))
        let next = button("chevron.down", "Next Match", #selector(nextMatch))
        let close = button("xmark", "Close Find Bar", #selector(closeTapped))
        let stack = NSStackView(views: [field, status, prev, next, close])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(field) }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        b.toolTip = label
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    @objc private func search() { find(backwards: false) }
    /// Edit > Find Next / Find Previous (⌘G / ⇧⌘G).
    func findAgain(backwards: Bool) { find(backwards: backwards) }
    @objc private func previous() { find(backwards: true) }
    @objc private func nextMatch() { find(backwards: false) }
    @objc private func closeTapped() { onClose?() }

    private func find(backwards: Bool) {
        guard let webView, !field.stringValue.isEmpty else { status.stringValue = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(field.stringValue, configuration: config) { [weak self] result in
            MainActor.assumeIsolated { self?.status.stringValue = result.matchFound ? "" : "No matches" }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSEvent.modifierFlags.contains(.shift)); return true
        default: return false
        }
    }
}

/// A transient confirmation pill at the bottom of the window.
@MainActor
enum Toast {
    private static weak var current: NSView?

    static func show(_ text: String, in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        // One at a time: a second toast used to land on top of the first.
        current?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        pill.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pill)
        current = pill
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 28),
            pill.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        pill.setAccessibilityRole(.staticText)
        NSAccessibility.post(element: pill, notification: .announcementRequested, userInfo: [.announcement: text])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; pill.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { pill.removeFromSuperview() } })
        }
    }
}
