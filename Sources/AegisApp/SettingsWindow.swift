import AppKit
import SwiftUI
import BrowserCore

/// The Settings dashboard: a resizable window with a sidebar of panes, each
/// a grid of cards. SwiftUI leaf hosted in AppKit.
///
/// Why the old window came up empty: it hosted a `.grouped` `Form` in an
/// `NSHostingController` and let the window size itself from the hosting
/// controller. A grouped Form is a scroll view with no ideal height, so the
/// controller's preferred/fitting size collapsed and the window opened with
/// nothing visible. Here the window gets an explicit content rect, the
/// hosting view is told not to drive the window size (`sizingOptions = []`),
/// and the root view fills whatever frame it is given.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var model: SettingsModel?

    func show(services: AppServices, pane: SettingsPane? = nil) {
        if let window, let model {
            if let pane { model.pane = pane }
            model.resync()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel(services: services)
        if let pane { model.pane = pane }
        let host = NSHostingView(rootView: SettingsRootView(model: model))
        host.sizingOptions = []

        let w = SettingsNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 780, height: 520)
        w.contentView = host
        w.setFrameAutosaveName("AegisSettings")
        if !w.setFrameUsingName("AegisSettings") { w.center() }
        w.delegate = self
        window = w
        self.model = model
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { model?.resync() }

    // MARK: Debug snapshot

    /// `Aegis --settings-snapshot out.png [--settings-pane spaces|all] [--dark]`
    /// opens Settings, renders the window with `cacheDisplay` (no screen
    /// recording permission needed) and quits. With `all`, writes
    /// `out-<pane>.png` for every pane. Not reachable from the UI.
    static func runDebugSnapshotIfRequested(services: AppServices) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--settings-snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let paneArg = args.firstIndex(of: "--settings-pane").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let panes: [SettingsPane] = paneArg == "all" ? SettingsPane.allCases : [paneArg.flatMap(SettingsPane.init(rawValue:)) ?? .appearance]
        shared.show(services: services, pane: panes[0])
        shared.window?.setFrameAutosaveName("")  // don't persist debug sizes
        if args.contains("--settings-tall"), let w = shared.window {
            // Tall enough to see each pane without scrolling.
            w.setContentSize(NSSize(width: 920, height: 1240))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for pane in panes {
                shared.model?.pane = pane
                try? await Task.sleep(for: .seconds(pane == .passwords || pane == .extensions ? 1.2 : 0.6))
                let url = panes.count == 1 ? out
                    : out.deletingLastPathComponent().appending(path: "\(out.deletingPathExtension().lastPathComponent)-\(pane.rawValue).png")
                shared.capture(to: url)
            }
            NSApp.terminate(nil)
        }
    }

    private func capture(to url: URL) {
        // Render the frame view (content + titlebar, so the traffic lights show).
        guard let content = window?.contentView, let frameView = content.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SETTINGS_SNAPSHOT \(url.path) \(Int(bounds.width))x\(Int(bounds.height))"); fflush(stdout)
    }
}

/// Handles ⌘W itself: the main menu's ⌘W is "Close Tab", aimed at the
/// browser window, so without this it would close a tab behind Settings.
private final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Root

struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 216)
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsColors.page(scheme))
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.pane {
                case .appearance: AppearancePane(model: model)
                case .spaces: SpacesPane(model: model)
                case .privacy: PrivacyPane(model: model)
                case .tabs: TabsPane(model: model)
                case .passwords: PasswordsPane(model: model)
                case .extensions: ExtensionsPane(model: model)
                case .downloads: DownloadsPane(model: model)
                case .about: AboutPane(model: model)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .id(model.pane)
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                SidebarItem(pane: pane, selected: model.pane == pane) { model.pane = pane }
                if pane == .spaces || pane == .tabs || pane == .downloads {
                    Spacer().frame(height: 10)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 52)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SidebarMaterial()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.tint.gradient))
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The system sidebar material behind the pane list.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
