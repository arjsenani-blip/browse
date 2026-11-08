import AppKit
import Credentials

/// A small glass banner at the top of the window for "Fill password?" and
/// "Save password?". Never modal, never blocks typing; dismisses itself.
@MainActor
enum CredentialBanner {
    private static weak var current: NSView?

    static func offerFill(suggestion: CredentialSuggestion, count: Int, in window: NSWindow?, fill: @escaping () -> Void) {
        let more = count > 1 ? " (+\(count - 1) more)" : ""
        show(in: window, symbol: "key.fill",
             text: "Fill password for \(suggestion.credential.username)\(more)?",
             primary: "Fill", secondary: "Not Now", timeout: 12, primaryAction: fill)
    }

    static func offerSave(_ decision: SubmitDecision, in window: NSWindow?, credentials: CredentialsCoordinator, password: String) {
        switch decision {
        case .nothing:
            return
        case .offerSave(let host, let username):
            show(in: window, symbol: "key",
                 text: "Save password for \(username) on \(host)?",
                 primary: "Save", secondary: "Never for This Site", timeout: 20,
                 primaryAction: { Task { try? await credentials.confirmSave(host: host, username: username, password: password) } },
                 secondaryAction: { Task { await credentials.neverSave(host: host) } })
        case .offerUpdate(let id, let host, let username):
            show(in: window, symbol: "key",
                 text: "Update saved password for \(username) on \(host)?",
                 primary: "Update", secondary: "Not Now", timeout: 20,
                 primaryAction: { Task { try? await credentials.confirmUpdate(credentialID: id, password: password) } })
        }
    }

    static func show(in window: NSWindow?, symbol: String, text: String, primary: String, secondary: String,
                             timeout: TimeInterval, primaryAction: @escaping () -> Void, secondaryAction: (() -> Void)? = nil) {
        guard let content = window?.contentView else { return }
        current?.removeFromSuperview()
        let banner = NSVisualEffectView()
        banner.material = .popover
        banner.state = .active
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 14
        banner.layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        let close = { [weak banner] in banner?.removeFromSuperview() }
        let yes = ActionButton(title: primary) { primaryAction(); close() }
        yes.keyEquivalent = ""
        yes.bezelStyle = .push
        yes.controlSize = .small
        let no = ActionButton(title: secondary) { secondaryAction?(); close() }
        no.bezelStyle = .push
        no.controlSize = .small
        let stack = NSStackView(views: [icon, label, no, yes])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        banner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(banner)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: banner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
        ])
        current = banner
        NSAccessibility.post(element: banner, notification: .announcementRequested, userInfo: [.announcement: text])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak banner] in banner?.removeFromSuperview() }
    }
}

final class ActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
