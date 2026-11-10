import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

struct SpacesPane: View {
    @Bindable var model: SettingsModel
    @State private var confirmDelete: Space?

    private var selected: Space? {
        model.store.spaces.first { $0.id == model.selectedSpaceID } ?? model.store.spaces.first
    }

    var body: some View {
        SettingsPageHeader(title: "Spaces", subtitle: "Each space keeps its own tabs and gradient, and can keep its own cookies and logins.")

        HStack(alignment: .top, spacing: 16) {
            SpaceList(model: model, selectedID: selected?.id)
                .frame(width: 236)
                .frame(maxHeight: .infinity, alignment: .top)
            if let space = selected {
                VStack(spacing: 16) {
                    SpaceDetail(model: model, space: space) { confirmDelete = space }
                    GradientEditor(model: model, space: space)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .alert("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { space in
            Button("Delete", role: .destructive) { model.deleteSpace(space.id) }
            Button("Cancel", role: .cancel) {}
        } message: { space in
            Text("Closes its \(space.allTabs.count) tabs and deletes the space's cookies and website data.")
        }
    }
}

// MARK: - List

private struct SpaceList: View {
    @Bindable var model: SettingsModel
    let selectedID: UUID?
    @State private var dragging: UUID?

    var body: some View {
        SettingsCard(title: "Your spaces", padding: 12, fillHeight: true) {
            VStack(spacing: 2) {
                ForEach(model.store.spaces) { space in
                    SpaceRow(space: space,
                             selected: space.id == selectedID,
                             current: space.id == model.store.currentSpaceID,
                             isPrivate: model.isPrivate(space))
                        .onTapGesture { model.selectedSpaceID = space.id }
                        .onDrag {
                            dragging = space.id
                            return NSItemProvider(object: space.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceDropDelegate(target: space.id, dragging: $dragging, model: model))
                        .opacity(dragging == space.id ? 0.5 : 1)
                        .accessibilityAction(named: "Move up") { move(space, by: -1) }
                        .accessibilityAction(named: "Move down") { move(space, by: 1) }
                }
            }
            .animation(.smooth(duration: 0.2), value: model.store.spaces.map(\.id))
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button { model.addSpace() } label: {
                    Label("New Space", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("Drag to reorder").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func move(_ space: Space, by delta: Int) {
        let spaces = model.store.spaces
        guard let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { return }
        model.store.moveSpace(from: i, to: delta > 0 ? j + 1 : j)
        model.services.forEachController { $0.refresh() }
    }
}

private struct SpaceRow: View {
    let space: Space
    let selected: Bool
    let current: Bool
    let isPrivate: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            SpaceGradientView(theme: space.resolvedTheme)
                .frame(width: 20, height: 20)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text(space.name.isEmpty ? "Untitled" : space.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            if isPrivate { Image(systemName: "eyeglasses").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            if current { SettingsBadge(text: "Current") }
            Text("\(space.allTabs.count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(space.name), \(space.allTabs.count) tabs\(current ? ", current space" : "")")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Live reorder: the dragged row takes the place of whatever it hovers.
private struct SpaceDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let model: SettingsModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != target else { return }
            model.moveSpace(dragging, before: target)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragging = nil }
        return true
    }
}

// MARK: - Detail

private struct SpaceDetail: View {
    @Bindable var model: SettingsModel
    let space: Space
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = space.resolvedTheme
        let darkInk = theme.prefersDarkInk(dark: scheme == .dark)
        let sharing = model.spacesSharingProfile(with: space)
        let current = space.id == model.store.currentSpaceID

        SettingsCard(padding: 0) {
            // Hero: the gradient as the window will show it.
            ZStack(alignment: .bottomLeading) {
                SpaceGradientView(theme: theme)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name.isEmpty ? "Untitled" : space.name)
                            .font(.system(size: 20, weight: .bold))
                        Text(current ? "Current space" : "\(space.allTabs.count) tabs")
                            .font(.system(size: 11.5, weight: .medium))
                            .opacity(0.75)
                    }
                    Spacer()
                }
                .foregroundStyle(darkInk ? Color.black.opacity(0.85) : .white)
                .padding(16)
            }
            .frame(height: 112)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(title: "Name") {
                    TextField("Name", text: Binding(
                        get: { space.name },
                        set: { model.rename(space.id, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { if space.name.trimmingCharacters(in: .whitespaces).isEmpty { model.rename(space.id, to: "Space") } }
                }
                Divider()
                SettingsRow(title: sharing.isEmpty ? "Separate cookies & logins" : "Shares cookies & logins",
                            help: profileHelp(sharing: sharing),
                            systemImage: sharing.isEmpty ? "lock.fill" : "person.2.fill") {
                    SettingsBadge(text: model.isPrivate(space) ? "Private" : model.store.profile(for: space).name,
                                  tint: sharing.isEmpty ? .accentColor : .secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    countTile(space.favorites.count, "Favorites", "star.fill")
                    countTile(space.pinned.count, "Pinned", "pin.fill")
                    countTile(space.today.count, "Today", "sun.max.fill")
                }
                HStack {
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Space…", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(model.store.spaces.count < 2)
                    .help(model.store.spaces.count < 2 ? "The last space can't be deleted" : "Close its tabs and delete its website data")
                }
            }
            .padding(16)
        }
    }

    private func profileHelp(sharing: [Space]) -> String {
        if model.isPrivate(space) { return "A private space: nothing is saved to disk." }
        if sharing.isEmpty { return "Sites signed in here don't see your other spaces." }
        return "Same cookies as " + sharing.map(\.name).formatted(.list(type: .and)) + "."
    }

    private func countTile(_ n: Int, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(n)").font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsColors.well(scheme)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gradient editor

private struct GradientEditor: View {
    @Bindable var model: SettingsModel
    let space: Space

    var body: some View {
        let theme = space.resolvedTheme
        SettingsCard(title: "Gradient", help: "Pick a preset, or set the top and bottom colors yourself.") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 10), spacing: 8) {
                ForEach(SpaceTheme.presets, id: \.name) { preset in
                    let on = preset.theme.top == theme.top && preset.theme.bottom == theme.bottom
                    Button {
                        var t = preset.theme
                        t.grain = theme.grain
                        if preset.theme.intensity < 1 { t.intensity = theme.intensity == 1 ? 0.7 : theme.intensity }
                        model.setTheme(t, for: space.id)
                    } label: {
                        LinearGradient(colors: [Color(preset.theme.top), Color(preset.theme.bottom)], startPoint: .top, endPoint: .bottom)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .padding(2.5)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                }
            }
            Divider()
            HStack(spacing: 20) {
                colorWell("Top", \.top, theme)
                colorWell("Bottom", \.bottom, theme)
                Button {
                    var t = theme
                    swap(&t.top, &t.bottom)
                    model.setTheme(t, for: space.id)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Swap top and bottom")
                    .accessibilityLabel("Swap top and bottom colors")
                Spacer()
            }
            SettingsSliderRow(title: "Intensity", value: Binding(
                get: { theme.intensity },
                set: { var t = theme; t.intensity = $0; model.setTheme(t, for: space.id) }),
                range: 0...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            SettingsToggleRow(title: "Film grain", help: "A fine texture over the gradient.", isOn: Binding(
                get: { theme.grain },
                set: { var t = theme; t.grain = $0; model.setTheme(t, for: space.id) }))
        }
    }

    private func colorWell(_ label: String, _ key: WritableKeyPath<SpaceTheme, ThemeColor>, _ theme: SpaceTheme) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13))
            ColorPicker(label, selection: Binding(
                get: { Color(theme[keyPath: key]) },
                set: { var t = theme; t[keyPath: key] = ThemeColor($0); model.setTheme(t, for: space.id) }),
                supportsOpacity: false)
                .labelsHidden()
        }
    }
}
