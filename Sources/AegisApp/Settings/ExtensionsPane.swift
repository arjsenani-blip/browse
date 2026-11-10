import AppKit
import SwiftUI
import WebKit
import WebEngine

struct ExtensionsPane: View {
    @Bindable var model: SettingsModel
    @State private var link = ""
    @State private var confirmRemove: InstalledExtension?
    @State private var actionError: String?

    private var host: ExtensionHost { model.services.extensions }

    private var linkIsValid: Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return false }
        return host.storeExtensionID(for: url) != nil
    }

    var body: some View {
        let _ = model.tick
        let installed = host.extensions

        SettingsPageHeader(title: "Extensions", subtitle: "Chrome Web Store extensions, run by WebKit. Manifest V3 only.")

        SettingsCard(title: "Add from Chrome Web Store", help: "Paste an extension's store link, or open the store and click “Add to Aegis”.") {
            HStack(spacing: 8) {
                TextField("https://chromewebstore.google.com/detail/…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel("Chrome Web Store link")
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!linkIsValid)
                Button {
                    if let url = URL(string: "https://chromewebstore.google.com") { model.services.openExternal(url) }
                } label: { Label("Open Store", systemImage: "arrow.up.right.square") }
            }
            if !link.isEmpty && !linkIsValid {
                Text("That isn't a Chrome Web Store extension link.").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }

        SettingsCard(title: installed.isEmpty ? "Installed" : "Installed · \(installed.count)",
                     help: "Some APIs (blocking webRequest, offscreen, sidePanel, native messaging) aren't available in WebKit.") {
            if installed.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("No extensions yet").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { i, ext in
                        if i > 0 { Divider().padding(.leading, 48) }
                        ExtensionRow(
                            ext: ext,
                            icon: host.webExtension(for: ext.id)?.icon(for: CGSize(width: 32, height: 32)),
                            loaded: host.context(for: ext.id)?.isLoaded ?? false,
                            errors: host.errors(for: ext.id),
                            setEnabled: { on in
                                do { try host.setEnabled(on, for: ext.id) } catch { actionError = error.localizedDescription }
                                model.tick += 1
                            },
                            remove: { confirmRemove = ext })
                    }
                }
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.red)
            }
        }
        .task {
            // ExtensionHost isn't observable; poll lightly while this pane is visible
            // so installs started from the store page show up.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick += 1
            }
        }
        .alert("Remove “\(confirmRemove?.name ?? "")”?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { ext in
            Button("Remove", role: .destructive) {
                Task {
                    do { try await host.uninstall(id: ext.id) } catch { actionError = error.localizedDescription }
                    model.tick += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its data and settings are deleted.")
        }
    }

    private func add() {
        guard linkIsValid, let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
        model.services.installExtension(from: url)
        link = ""
    }
}

private struct ExtensionRow: View {
    let ext: InstalledExtension
    let icon: NSImage?
    let loaded: Bool
    let errors: [String]
    let setEnabled: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsPane.extensions.tint.gradient))
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(ext.version).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !ext.enabled {
                        SettingsBadge(text: "Off", tint: .secondary)
                    } else if loaded {
                        SettingsBadge(text: "Running", tint: .green)
                    } else {
                        SettingsBadge(text: "Not loaded", tint: .orange)
                    }
                    Text(ext.source == .webStore ? "Chrome Web Store" : "Unpacked")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(errors.prefix(3), id: \.self) { e in
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(get: { ext.enabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Enable \(ext.name)")
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove \(ext.name)")
        }
        .padding(.vertical, 9)
    }
}
