import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebEngine

struct DownloadsPane: View {
    @Bindable var model: SettingsModel

    private var folder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    var body: some View {
        let _ = model.tick
        let items = DownloadCenter.shared.items.reversed() as [DownloadCenter.Item]
        let active = items.filter { !$0.finished && !$0.failed }.count

        SettingsPageHeader(title: "Downloads", subtitle: "Files you download from any space. Open the full list with ⌥⌘J.")

        HStack(spacing: 12) {
            SettingsStat(value: "\(items.count)", label: "This session", systemImage: "arrow.down.circle.fill", tint: SettingsPane.downloads.tint)
            SettingsStat(value: "\(active)", label: "In progress", systemImage: "clock.arrow.circlepath", tint: active > 0 ? .orange : Color(red: 0.55, green: 0.56, blue: 0.60))
        }

        SettingsCard(title: "Save location", help: "Files with the same name get a number added.") {
            SettingsRow(title: folder.lastPathComponent, help: (folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder.fill") {
                Button("Show in Finder") { NSWorkspace.shared.open(folder) }.controlSize(.small)
            }
        }

        SettingsCard(title: "Recent") {
            Button("Clear Finished") {
                DownloadCenter.shared.clearFinished()
                model.tick += 1
            }
            .controlSize(.small)
            .disabled(!items.contains { $0.finished || $0.failed })
        } content: {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Nothing downloaded yet").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(50).enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 44) }
                        DownloadRow(item: item) {
                            DownloadCenter.shared.remove(item.id)
                            model.tick += 1
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick += 1
            }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadCenter.Item
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if !item.finished && !item.failed {
                    ProgressView(value: item.fractionCompleted).controlSize(.small).frame(maxWidth: 220)
                } else {
                    Text(status).font(.system(size: 11)).foregroundStyle(item.failed ? .red : .secondary)
                }
            }
            Spacer()
            if item.fileExists, let dest = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([dest]) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show \(item.filename) in Finder")
            }
            Button(action: remove) { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Remove from list").accessibilityLabel("Remove \(item.filename) from list")
        }
        .padding(.vertical, 7)
    }

    private var status: String {
        if item.failed { return "Failed" }
        var parts: [String] = []
        if item.totalBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)) }
        if let host = item.sourceURL?.host() { parts.append(host) }
        if !item.fileExists { parts.append("Moved or deleted") }
        return parts.joined(separator: " · ")
    }

    private var icon: NSImage {
        if let dest = item.destination, item.fileExists { return NSWorkspace.shared.icon(forFile: dest.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data)
    }
}
