import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A downloaded file as the Library shows it. Supplied by the app.
public struct LibraryItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var file: URL?
    public var source: URL?
    public var date: Date
    public var bytes: Int64
    /// nil once finished.
    public var progress: Double?
    public var failed: Bool
    public var isMedia: Bool
    public var exists: Bool
    public init(id: UUID, name: String, file: URL?, source: URL?, date: Date, bytes: Int64, progress: Double?, failed: Bool, isMedia: Bool, exists: Bool) {
        self.id = id; self.name = name; self.file = file; self.source = source; self.date = date
        self.bytes = bytes; self.progress = progress; self.failed = failed; self.isMedia = isMedia; self.exists = exists
    }
}

@MainActor
public protocol LibraryActions: AnyObject {
    func libraryOpen(_ item: LibraryItem)
    func libraryOpenInTab(_ item: LibraryItem)
    func libraryReveal(_ item: LibraryItem)
    func libraryRemove(_ item: LibraryItem)
    func libraryClearFinished()
}

@MainActor
@Observable
public final class LibraryModel {
    public enum Tab: String, CaseIterable { case downloads = "Downloads", media = "Media" }
    public var items: [LibraryItem] = []
    public var tab: Tab = .downloads
    public var accentHue: Double = 0.48
    weak var actions: LibraryActions?
    public init() {}
    var media: [LibraryItem] { items.filter { $0.isMedia && $0.exists && $0.progress == nil } }
}

struct LibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(LibraryModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()
            Group {
                switch model.tab {
                case .downloads: downloads
                case .media: media
                }
            }
            .frame(width: 360, height: 400)
        }
    }

    @ViewBuilder private var downloads: some View {
        if model.items.isEmpty {
            empty("No downloads yet", "Files you download appear here.", "arrow.down.circle")
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in
                            DownloadRow(item: item, hue: model.accentHue)
                                .onTapGesture(count: 2) { model.actions?.libraryOpen(item) }
                                .contextMenu {
                                    Button("Open") { model.actions?.libraryOpen(item) }.disabled(!item.exists)
                                    Button("Show in Finder") { model.actions?.libraryReveal(item) }.disabled(!item.exists)
                                    if let source = item.source {
                                        Button("Copy Download Link") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(source.absoluteString, forType: .string)
                                        }
                                    }
                                    Divider()
                                    Button("Remove from List") { model.actions?.libraryRemove(item) }
                                }
                                .onDrag { item.file.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                        }
                    }
                    .padding(8)
                }
                Divider()
                HStack {
                    Text("\(model.items.count) items").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.actions?.libraryClearFinished() }.controlSize(.small)
                }
                .padding(.horizontal, 12).frame(height: 34)
            }
        }
    }

    @ViewBuilder private var media: some View {
        if model.media.isEmpty {
            empty("No media yet", "Images, video and audio you download collect here.", "photo.on.rectangle")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(model.media) { item in
                        MediaTile(item: item)
                            .onTapGesture(count: 2) { model.actions?.libraryOpen(item) }
                            .onTapGesture { model.actions?.libraryOpenInTab(item) }
                            .contextMenu {
                                Button("Open in New Tab") { model.actions?.libraryOpenInTab(item) }
                                Button("Open") { model.actions?.libraryOpen(item) }
                                Button("Show in Finder") { model.actions?.libraryReveal(item) }
                            }
                            .onDrag { item.file.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                    }
                }
                .padding(10)
            }
        }
    }

    private func empty(_ title: String, _ hint: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DownloadRow: View {
    let item: LibraryItem
    let hue: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                .opacity(item.exists || item.progress != nil ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let progress = item.progress, !item.failed {
                    ProgressView(value: progress).controlSize(.small).tint(Color(nsColor: Tokens.accent(hue: hue)))
                } else {
                    Text(status).font(.system(size: 11)).foregroundStyle(item.failed ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).frame(height: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: NSImage {
        if let file = item.file, item.exists { return NSWorkspace.shared.icon(forFile: file.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }

    private var status: String {
        if item.failed { return "Failed" }
        if !item.exists { return "Moved or deleted" }
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let host = item.source?.host() ?? ""
        return [size, host, item.date.formatted(.relative(presentation: .named))].filter { !$0.isEmpty && $0 != "Zero KB" }.joined(separator: " · ")
    }
}

struct MediaTile: View {
    let item: LibraryItem
    @State private var thumb: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator, lineWidth: 0.5))
        .help(item.name)
        .task(id: item.file) {
            guard let file = item.file else { return }
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 208, height: 208), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumb = rep.nsImage
            }
        }
        .accessibilityLabel(item.name)
    }
}

/// Shows the Library in a popover anchored to a sidebar button.
@MainActor
public final class LibraryController {
    public let model = LibraryModel()
    private var popover: NSPopover?

    public init() {}

    public func toggle(relativeTo view: NSView, actions: LibraryActions, tab: LibraryModel.Tab? = nil) {
        if let popover, popover.isShown { popover.close(); return }
        model.actions = actions
        if let tab { model.tab = tab }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !Tokens.Motion.reduceMotion
        p.contentViewController = NSHostingController(rootView: LibraryView(model: model))
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        popover = p
    }
}
