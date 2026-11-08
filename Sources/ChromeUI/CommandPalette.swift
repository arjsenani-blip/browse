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

@MainActor
public protocol PaletteDataSource: AnyObject {
    /// Synchronous in-memory pass; must be fast (< 4 ms).
    func quickResults(for query: String, lastEditWasDeletion: Bool) -> (items: [PaletteItem], inline: String?)
    /// Full pass including history FTS; may be cancelled by the next keystroke.
    func fullResults(for query: String, lastEditWasDeletion: Bool) async -> (items: [PaletteItem], inline: String?)
    func perform(_ item: PaletteItem, query: String, modifiers: NSEvent.ModifierFlags)
    /// Enter with no selection: navigate to/search the raw text.
    func submit(_ text: String, modifiers: NSEvent.ModifierFlags)
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
    public var placeholder = "Search tabs, history, or type a command"
    weak var dataSource: PaletteDataSource?
    var onDismiss: (() -> Void)?
    private var task: Task<Void, Never>?

    public init() {}

    func refresh(deletion: Bool) {
        guard let dataSource else { return }
        let q = query
        let quick = dataSource.quickResults(for: q, lastEditWasDeletion: deletion)
        items = quick.items
        inlineCompletion = quick.inline
        selection = 0
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let full = await dataSource.fullResults(for: q, lastEditWasDeletion: deletion)
            guard !Task.isCancelled, self.query == q else { return }
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
        } else {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 15, weight: .medium))
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
                Text("All")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

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
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.palette, style: .continuous).stroke(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 16)
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .padding(48)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { model.onDismiss?(); return .handled }
        .onKeyPress(.tab) { model.acceptInline(); return .handled }
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
        .onAppear { focused = true }
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
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
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
        model.refresh(deletion: false)
        model.query = initialText

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
