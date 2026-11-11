import AppKit
import SwiftUI

/// One row in the palette, supplied by the app from the Search module.
public struct PaletteItem: Identifiable, Equatable, Sendable {
    public enum Section: String, Sendable, CaseIterable {
        case switchToTab = "Switch to Tab"
        case bookmarks = "Favorites"
        case history = "History"
        case actions = "Actions"
        case search = "Search"
    }
    public var id: String
    public var section: Section
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var shortcut: String?
    /// UTF-16 offsets into `title` to bold.
    public var highlights: [Range<Int>]
    public var url: URL?
    public init(id: String, section: Section, title: String, subtitle: String = "", symbol: String, shortcut: String? = nil, highlights: [Range<Int>] = [], url: URL? = nil) {
        self.id = id; self.section = section; self.title = title; self.subtitle = subtitle
        self.symbol = symbol; self.shortcut = shortcut; self.highlights = highlights; self.url = url
    }
}

/// A one-off card above the results when the field is empty (e.g. "Coming from Arc?").
public struct PaletteBanner {
    public var symbol: String
    public var title: String
    public var subtitle: String
    public var actionTitle: String
    public var action: @MainActor () -> Void
    public init(symbol: String, title: String, subtitle: String, actionTitle: String, action: @escaping @MainActor () -> Void) {
        self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.actionTitle = actionTitle; self.action = action
    }
}

@MainActor
public protocol PaletteDataSource: AnyObject {
    /// Shown above results while the field is empty.
    func banner() -> PaletteBanner?
    /// Synchronous in-memory pass; must be fast (< 4 ms).
    func quickResults(for query: String, lastEditWasDeletion: Bool) -> (items: [PaletteItem], inline: String?)
    /// Full pass including history FTS; may be cancelled by the next keystroke.
    func fullResults(for query: String, lastEditWasDeletion: Bool) async -> (items: [PaletteItem], inline: String?)
    func perform(_ item: PaletteItem, query: String, modifiers: NSEvent.ModifierFlags)
    /// Enter with no selection: navigate to/search the raw text.
    func submit(_ text: String, modifiers: NSEvent.ModifierFlags)
}

public extension PaletteDataSource {
    func banner() -> PaletteBanner? { nil }
}

@MainActor
@Observable
public final class PaletteModel {
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            refresh(deletion: query.count < oldValue.count)
        }
    }
    public private(set) var items: [PaletteItem] = []
    public private(set) var inlineCompletion: String?
    public var selection = 0
    public var accentHue: Double = 0.48
    /// Commands-only mode, shown as a chip; the data source still sees the ">" prefix.
    public var commandsOnly = false {
        didSet { if commandsOnly != oldValue { refresh(deletion: false) } }
    }
    private var effectiveQuery: String { commandsOnly ? ">" + query : query }
    public var placeholder = "Search tabs, history, or type a command"
    weak var dataSource: PaletteDataSource?
    var onDismiss: (() -> Void)?
    var banner: PaletteBanner?
    private var task: Task<Void, Never>?

    public init() {}

    func refresh(deletion: Bool) {
        guard let dataSource else { return }
        let q = effectiveQuery
        let quick = dataSource.quickResults(for: q, lastEditWasDeletion: deletion)
        items = quick.items
        inlineCompletion = quick.inline
        selection = 0
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let full = await dataSource.fullResults(for: q, lastEditWasDeletion: deletion)
            guard !Task.isCancelled, self.effectiveQuery == q else { return }
            let selectedID = self.items.indices.contains(self.selection) ? self.items[self.selection].id : nil
            self.items = full.items
            self.inlineCompletion = full.inline
            self.selection = selectedID.flatMap { id in full.items.firstIndex { $0.id == id } } ?? 0
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    func activate(modifiers: NSEvent.ModifierFlags) {
        if items.indices.contains(selection) {
            dataSource?.perform(items[selection], query: query, modifiers: modifiers)
        } else if !commandsOnly {
            dataSource?.submit(query, modifiers: modifiers)
        }
        onDismiss?()
    }

    func acceptInline() {
        if let inline = inlineCompletion { query = inline }
    }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 15, weight: .medium))
                if model.commandsOnly {
                    Text("Actions")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: Tokens.selectionFill(hue: model.accentHue))))
                        .accessibilityLabel("Actions only. Delete to search everything.")
                }
                ZStack(alignment: .leading) {
                    if let inline = model.inlineCompletion, inline.lowercased().hasPrefix(model.query.lowercased()), !model.query.isEmpty {
                        (Text(model.query).foregroundStyle(.clear) + Text(inline.dropFirst(model.query.count)).foregroundStyle(.tertiary))
                            .font(.system(size: 17))
                            .lineLimit(1)
                    }
                    TextField(model.placeholder, text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { model.activate(modifiers: NSEvent.modifierFlags) }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if let banner = model.banner, model.query.isEmpty, !model.commandsOnly {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: banner.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: Tokens.accent(hue: model.accentHue))))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title).font(.system(size: 13.5, weight: .semibold))
                        Text(banner.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button(banner.actionTitle) { model.onDismiss?(); banner.action() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(nsColor: Tokens.accent(hue: model.accentHue)))
                        .controlSize(.regular)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: Tokens.selectionFill(hue: model.accentHue))))
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, model.items.isEmpty ? 10 : 2)
                .accessibilityElement(children: .combine)
            }

            if !model.items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || model.items[index - 1].section != item.section {
                                    Text(item.section.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 6 : 10)
                                        .padding(.bottom, 2)
                                }
                                PaletteRow(item: item, selected: index == model.selection, hue: model.accentHue)
                                    .id(item.id)
                                    .onTapGesture { model.selection = index; model.activate(modifiers: []) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: model.selection) { _, new in
                        if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text("Results stay on this Mac")
                Spacer()
                Text("↑↓ to move · ↵ to open · ⌘↵ new tab · esc")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 32)
        }
        .frame(width: Tokens.Size.paletteWidth)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: Tokens.Radius.palette, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: Tokens.Radius.palette, style: .continuous).fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.palette, style: .continuous))
        // A visible edge in dark mode, where the panel would otherwise match the page.
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.palette, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: colorScheme == .dark ? 1 : 0.5))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 16)
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .padding(48)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { model.onDismiss?(); return .handled }
        .onKeyPress(.tab) { model.acceptInline(); return .handled }
        .onKeyPress(.delete) {
            // Backspace on an empty field leaves Actions mode.
            if model.commandsOnly && model.query.isEmpty { model.commandsOnly = false; return .handled }
            return .ignored
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            if press.modifiers.contains(.command) || press.modifiers.contains(.shift) {
                var flags: NSEvent.ModifierFlags = []
                if press.modifiers.contains(.command) { flags.insert(.command) }
                if press.modifiers.contains(.shift) { flags.insert(.shift) }
                model.activate(modifiers: flags)
                return .handled
            }
            return .ignored
        }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            focused = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.82)) { appeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    let hue: Double

    var body: some View {
        HStack(spacing: 12) {
            PaletteIcon(item: item)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                highlighted.lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: item.subtitle.isEmpty ? 38 : 46)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color(nsColor: Tokens.selectionFill(hue: hue)) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var highlighted: Text {
        let utf16 = Array(item.title.utf16)
        var result = Text("")
        var cursor = 0
        for r in item.highlights.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= cursor && r.upperBound <= utf16.count {
            result = result + Text(String(utf16CodeUnits: Array(utf16[cursor..<r.lowerBound]), count: r.lowerBound - cursor))
            result = result + Text(String(utf16CodeUnits: Array(utf16[r]), count: r.count)).fontWeight(.semibold)
            cursor = r.upperBound
        }
        result = result + Text(String(utf16CodeUnits: Array(utf16[cursor...]), count: utf16.count - cursor))
        return result.font(.system(size: 13.5))
    }
}

/// Hosts the palette over a window's content, with a light scrim.
@MainActor
public final class PaletteController {
    public let model = PaletteModel()
    private var host: NSView?
    private weak var window: NSWindow?
    /// The model only references its source weakly; the controller owns it while open.
    private var source: PaletteDataSource?
    private var paletteView: NSView?

    public init() {}
    /// Called when the palette closes (the window restores what it hid).
    public var onClose: (() -> Void)?

    public var isOpen: Bool { host != nil }

    public func show(in window: NSWindow, over anchor: NSView? = nil, dataSource: PaletteDataSource, initialText: String = "", hue: Double) {
        guard let content = window.contentView else { return }
        if isOpen { dismiss() }
        self.window = window
        source = dataSource
        model.dataSource = dataSource
        model.accentHue = hue
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.query = ""
        model.banner = dataSource.banner()
        // ">" opens Actions mode as a chip rather than a visible character.
        model.commandsOnly = initialText == ">"
        model.refresh(deletion: false)
        model.query = initialText == ">" ? "" : initialText

        let scrim = PaletteScrim()
        scrim.onClick = { [weak self] in self?.dismiss() }
        scrim.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrim)
        let hosting = NSHostingView(rootView: PaletteView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: content.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hosting.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hosting.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            hosting.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            hosting.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -content.bounds.height * 0.12),
        ])
        host = scrim
        paletteView = hosting
        scrim.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(0.16)
            scrim.animator().alphaValue = 0.55
        }
    }

    public func dismiss() {
        guard let host else { return }
        self.host = nil
        onClose?()
        let palette = paletteView
        paletteView = nil
        model.dataSource = nil
        source = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tokens.Motion.duration(0.12)
            host.animator().alphaValue = 0
            palette?.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { host.removeFromSuperview(); palette?.removeFromSuperview() }
        })
        window?.makeFirstResponder(window?.contentView)
    }
}

final class PaletteScrim: NSVisualEffectView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        // A faint blur of the app behind the palette (plain dim with Reduce Transparency).
        material = .fullScreenUI
        blendingMode = .withinWindow
        state = .active
        alphaValue = 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            material = .windowBackground
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        if hitTest(convert(event.locationInWindow, from: nil)) === self { onClick?() }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}

/// A row's icon: the site's own favicon for tabs, history and favorites;
/// the SF Symbol for actions and search.
struct PaletteIcon: View {
    let item: PaletteItem
    @State private var favicon: NSImage?

    var body: some View {
        Group {
            if let favicon, item.section != .actions, item.section != .search {
                Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.url) {
            guard item.section != .actions, item.section != .search, let url = item.url else { favicon = nil; return }
            if let cached = Favicons.shared.cached(for: url) { favicon = cached; return }
            Favicons.shared.load(for: url) { image in favicon = image }
        }
    }
}
