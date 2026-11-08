# Chrome extension support: integration guide

Everything in `Sources/WebEngine/Extensions/` is self-contained and builds today. To turn it on, the lead
adds about 60 lines to existing files, listed below. Nothing here touches the network until the user clicks
**Add to Aegis**.

## Files

| File | What it is |
|---|---|
| `CRXPackage.swift` | CRX2/CRX3 parser and signature verifier (`CRXPackage`, `CRXError`), plus `ChromeExtensionID` (ID validation, ID from public key, ID from a Web Store URL). |
| `ChromeWebStore.swift` | `ChromeWebStore.downloadCRX(id:)`, `downloadURL(for:)`, `isStorePage(_:)`. Uses an ephemeral session with no cookies, cache or credentials, and follows redirects only to `clients2.google.com` and `clients2.googleusercontent.com`. |
| `ExtensionInstaller.swift` | `ExtensionInstaller`: checks the ZIP, extracts it with `/usr/bin/ditto -x -k` into a staging folder, strips `_metadata`, then moves the folder into `~/Library/Application Support/Aegis/Extensions/<id>/`. Also holds `ExtensionManifest` (name, version, permissions, hosts, content-script matches, `__MSG_` localization) and `ZIPInspector`. |
| `ExtensionState.swift` | `InstalledExtension` (the record saved in `state.json`), `ExtensionPermissionRequest` (consent sheet contents, including `summary` lines), `ExtensionPermissionGrant`. |
| `ExtensionHost.swift` | `@MainActor ExtensionHost`: owns the `WKWebExtensionController`, handles install/uninstall/enable, consent and grants, actions and commands, and implements the controller delegate. |
| `ExtensionAdapters.swift` | `ExtensionTabAdapter` (a `WKWebExtensionTab` built from closures) and `ExtensionWindowAdapter` (a `WKWebExtensionWindow` built from closures, with an `init(window: NSWindow, …)` convenience). |
| `WebTab+Extensions.swift` | `host.adapter(for: WebTab, …)`, `host.webTabDidChange(_:)` (notifies only when title, URL, loading or audio changes), `host.webTabDidClose(_:)`. |
| `ExtensionCompatibility.swift` | Permissions WebKit supports, plus notes on common Chrome permissions it doesn't. Use it for warnings on the consent sheet. |

## 1. Own one host (AppServices.swift)

```swift
// properties
let extensions: ExtensionHost

// init(), after `runtime = TabRuntime(store: store)`
extensions = ExtensionHost()            // default root: ~/Library/Application Support/Aegis/Extensions
runtime.extensionHost = extensions      // see step 2

// start(), after runtime.delegate = self
wireExtensions()                        // step 4
Task { await extensions.loadInstalled() }
```

`websiteDataStore:` is optional. Pass the default profile's store if `chrome.cookies` should see that
profile's cookies. Otherwise WebKit uses `WKWebsiteDataStore.default()`. Tabs in other profiles still carry
their own store.

## 2. Attach the controller to every browsing web view (TabRuntime.swift and ProfileContext.swift)

Content scripts, declarativeNetRequest rules and tab APIs only reach web views whose
`WKWebViewConfiguration.webExtensionController` is set before the view is created.

```swift
// TabRuntime: new property
public weak var extensionHost: ExtensionHost?
// TabRuntime.context(for:), after creating `c`
c.extensionHost = extensionHost

// ProfileContext: new property
weak var extensionHost: ExtensionHost?
// ProfileContext.makeConfiguration(), just before `return config`
extensionHost?.configure(config)
```

`TabRuntime.adopt(_:configuration:)` already reuses WebKit's configuration, which keeps the controller.

**Private windows:** these profiles use `.nonPersistent()` data stores, so WebKit treats their views as
private and extensions do nothing there, by design. The test `injectsContentScriptsOnlyIntoNonPrivateViews`
proves this. To allow an extension in private windows, pass `allowInPrivate: true` in its
`ExtensionPermissionGrant`.

## 3. Tabs (AppServices.swift, the WebTabDelegate extension)

Create exactly one adapter per tab. WebKit tracks tabs by object identity.

```swift
func extensionTab(_ tab: WebTab) -> ExtensionTabAdapter {
    extensions.adapter(for: tab,
        isSelected: { [weak self] in self?.store.currentSpace.selected == tab.id },
        window:     { [weak self] in self?.controller(containing: tab.id)?.extensionWindow },
        activate:   { [weak self] in self?.controller(containing: tab.id)?.select(tab.id) },
        close:      { [weak self] in self?.controller(containing: tab.id)?.closeTab(tab.id) })
}
```

Then add these calls:

| Where | Add |
|---|---|
| `webTabDidChange(_:)` (first line) | `extensions.webTabDidChange(tab)` |
| Tab created (`TabRuntime.tab(_:)` creates a `WebTab`; easiest hook is right after `runtime.tab(id)` returns a new tab, or in `store.openTab` callers) | `extensions.didOpen(tab: extensionTab(t))` |
| `BrowserWindowController.select(_:)`, after `store.select(id)` | `app.extensions.didActivate(tab: app.extensionTab(new), previous: old.map(app.extensionTab))` |
| `BrowserWindowController.closeTab(_:)`, before `runtime.discard(id)` | `if let w = runtime.tab(id) { app.extensions.webTabDidClose(w) }` |

Don't call `didClose` when a tab hibernates. A sleeping tab keeps its adapter, `webView()` returns nil, and
WebKit skips injection until it wakes.

## 4. Windows and delegate callbacks

In `BrowserWindowController`:

```swift
lazy var extensionWindow = app.extensions.windowAdapter(for: self) {
    ExtensionWindowAdapter(window: window!,
        tabs: { [unowned self] in store.currentSpace.allTabs.compactMap { runtime.tab($0) }.map(app.extensionTab) },
        activeTab: { [unowned self] in store.currentSpace.selected.flatMap { runtime.tab($0) }.map(app.extensionTab) },
        isPrivate: /* this window's space profile is ephemeral */ false)
}
// after showWindow:              app.extensions.didOpen(window: extensionWindow)
// windowDidBecomeKey:            app.extensions.didFocus(window: extensionWindow)
// windowWillClose (first line):  app.extensions.didClose(window: extensionWindow, owner: self)
```

In `AppServices.wireExtensions()`:

```swift
extensions.openWindows = { [unowned self] in
    // Focused window first.
    controllers.sorted { a, _ in a.window?.isKeyWindow == true }.map(\.extensionWindow)
}
extensions.openTab = { [unowned self] req in            // chrome.tabs.create, options-page fallback
    guard let c = frontController else { return nil }
    let id = store.openTab(req.url, select: req.active)
    if let url = req.url, req.active { runtime.tab(id)?.load(url) }
    return runtime.tab(id).map(extensionTab)
}
extensions.openWindow = nil                              // optional: chrome.windows.create; nil refuses
extensions.presentActionPopup = { [unowned self] action, id in
    // WebKit gives a ready NSPopover on macOS; anchor it to the toolbar button.
    guard let button = frontController?.extensionButton(for: id) else { return }
    action.popupPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    // Or host action.popupWebView in your own popover.
}
extensions.actionDidUpdate = { [unowned self] action, id in frontController?.refreshExtensionButton(id, action) }
extensions.promptForPermissions = { prompt in            // runtime permissions.request()
    await PermissionSheet.ask(prompt)                    // return .deny or a subset
}
extensions.openOptionsPage = { url, config, id in
    // `config` must be used for the web view that loads `url` (a webkit-extension:// page).
    // Simplest: a small NSWindow/NSPanel holding WKWebView(frame:configuration: config!).
}
extensions.onChange = { [unowned self] in /* refresh the toolbar and the extensions settings list */ }
```

## 5. Toolbar buttons

For each `extensions.extensions` entry where `enabled` is true and `extensions.context(for:)?.isLoaded` is
true:

- Icon: `extensions.action(for: id, tab: currentTab)?.icon(for: CGSize(width: 16, height: 16))`
- Label: `action.label`
- Badge: `action.badgeText`
- Click: `extensions.performAction(for: id, tab: currentTab)`. This grants `activeTab`, then either fires
  `action.onClicked` or loads the popup and calls `presentActionPopup`.

## 6. "Add to Aegis" on Web Store pages

The store's own Install button won't work in Aegis: it checks for Chrome and uses Chrome-only APIs. Show
our own banner instead.

```swift
// AppServices.webTab(_:didCommit:…)
if let id = extensions.storeExtensionID(for: url) {
    StoreBanner.show(in: frontController, installed: extensions.isInstalled(id)) { [unowned self] in
        Task {
            do {
                let ext = try await extensions.install(fromWebStoreURL: url)   // downloads, verifies, unpacks; doesn't load
                let request = extensions.pendingPermissions(for: ext.id)!
                let warnings = ExtensionCompatibility.unsupported(in: try ExtensionManifest.read(
                    from: extensions.installer.directory(for: ext.id)))
                if await ConsentSheet.ask(request, warnings: warnings) {      // shows request.summary
                    try extensions.grant(ExtensionPermissionGrant(request))   // loads it
                } else {
                    try await extensions.uninstall(id: ext.id)
                }
            } catch { /* show the error */ }
        }
    }
}
```

To install from a store URL in the address bar or palette, call `extensions.install(fromWebStoreURL:)`. It
also accepts a bare 32-character ID via `ChromeExtensionID.fromWebStoreURL(String)`.

## 7. Keyboard commands and context menus (optional)

- `BrowserWindowController` key handling: `if app.extensions.performCommand(for: event) { return true }`
- `WKUIDelegate` context menu: append `app.extensions.menuItems(for: extensionTab(tab))`

## 8. Settings list

- Status: `extensions.status(for: id)` returns the record, `isLoaded`, `errors`, and `pending`.
- Enable or disable: `extensions.setEnabled(_:for:)`
- Remove: `extensions.uninstall(id:)`. This also deletes the extension's storage.
- Revoke a host: `extensions.revoke(ExtensionPermissionGrant(extensionID:, permissions: [], matchPatterns: [host]))`

## 9. Housekeeping

- **ThirdPartyNotices.md:** add an entry. The CRX3 verification in `CRXPackage.swift` is adapted from
  DuckDuckGo's `ChromeWebStorePackageVerifier.swift` (github.com/duckduckgo/apple-browsers),
  Copyright © DuckDuckGo, Apache License 2.0.
- **CLAUDE.md "Zero telemetry" rule:** add an exception. `clients2.google.com` and
  `clients2.googleusercontent.com` are contacted only when the user installs an extension. There are no
  background update checks yet.
- **Package.swift:** CryptoKit and Security are system frameworks, so no new dependencies. This `.md` file
  makes SwiftPM warn "found 1 file(s) which are unhandled". Either add
  `exclude: ["Extensions/INTEGRATION.md"]` to the `WebEngine` target, or delete this file once you've
  integrated.
- **Debug:** `ctx.isInspectable` is true in DEBUG builds, so background pages show up in Safari's Develop
  menu.
