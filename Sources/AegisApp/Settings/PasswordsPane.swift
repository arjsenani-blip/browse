import AppKit
import SwiftUI
import Credentials

struct PasswordsPane: View {
    @Bindable var model: SettingsModel
    @State private var credentials: [Credential] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var query = ""
    @State private var confirmDelete: Credential?

    private var filtered: [Credential] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = credentials.sorted { $0.host < $1.host }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.host.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        SettingsPageHeader(title: "Passwords", subtitle: "Saved in your Mac's Keychain. Aegis offers to fill them on matching sites.")

        HStack(spacing: 12) {
            SettingsStat(value: loaded ? "\(credentials.count)" : "…", label: "Saved passwords", systemImage: "key.fill", tint: SettingsPane.passwords.tint)
            SettingsStat(value: model.passkeysReady ? "On" : "Unavailable", label: "Passkeys", systemImage: "person.badge.key.fill", tint: model.passkeysReady ? .green : Color(red: 0.55, green: 0.56, blue: 0.60))
        }

        SettingsCard(title: "Import", help: "Bring passwords from the Passwords app, Safari or Chrome, or everything from another browser.") {
            HStack(spacing: 10) {
                Button {
                    (NSApp.delegate as? AppDelegate)?.importPasswords()
                    Task { try? await Task.sleep(for: .seconds(2)); await load() }
                } label: { Label("Import Passwords from CSV…", systemImage: "doc.badge.arrow.up") }
                Button {
                    (NSApp.delegate as? AppDelegate)?.importBrowserData()
                } label: { Label("Import from Other Browsers…", systemImage: "square.and.arrow.down.on.square") }
                Spacer()
            }
            .controlSize(.regular)
        }

        SettingsCard(title: "Saved", help: nil) {
            searchField
        } content: {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !loaded {
                HStack { ProgressView().controlSize(.small); Text("Reading Keychain…").foregroundStyle(.secondary) }
                    .font(.system(size: 12))
            } else if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "key.horizontal").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text(credentials.isEmpty ? "No saved passwords yet" : "No matches for “\(query)”")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.leading, 40) }
                        CredentialRow(credential: c) { confirmDelete = c }
                    }
                }
            }
        }

        SettingsCard(title: "Passkeys", help: "Passkeys from iCloud Keychain need an entitlement Apple grants to browsers.") {
            SettingsRow(title: model.passkeyStatus, systemImage: model.passkeysReady ? "checkmark.seal.fill" : "exclamationmark.circle") { EmptyView() }
        }
        .task { await load() }
        .alert("Delete the password for \(confirmDelete?.host ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { c in
            Button("Delete", role: .destructive) {
                Task {
                    try? await model.services.passwords.delete(id: c.id)
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text("“\(c.username.isEmpty ? "(no username)" : c.username)” is removed from the Keychain.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(width: 190, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("Search passwords")
    }

    private func load() async {
        do {
            credentials = try await model.services.passwords.allCredentials()
            loadError = nil
        } catch {
            loadError = "Couldn't read the Keychain: \(error.localizedDescription)"
        }
        loaded = true
    }
}

private struct CredentialRow: View {
    let credential: Credential
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(String(credential.host.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(credential.host).font(.system(size: 13)).lineLimit(1)
                Text(credential.username.isEmpty ? "No username" : credential.username)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let used = credential.lastUsed {
                Text("Used \(used.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0.35)
                .help("Delete")
                .accessibilityLabel("Delete password for \(credential.host)")
        }
        .padding(.vertical, 7)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var color: Color {
        let hue = Double(credential.host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.75)
    }
}
