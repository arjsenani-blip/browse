import CryptoKit
import Foundation
import Security
import Testing
import WebKit
@testable import WebEngine
import BrowserCore

// MARK: - Fixtures

enum Fixture {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "aegis-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ files: [String: String], to dir: URL) throws {
        for (path, body) in files {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
    }

    /// A real ZIP made by ditto from a folder of files.
    static func zip(_ files: [String: String]) async throws -> Data {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "src", directoryHint: .isDirectory)
        try write(files, to: src)
        let out = dir.appending(path: "out.zip")
        try await ExtensionInstaller.ditto(["-c", "-k", "--norsrc", src.path, out.path])
        return try Data(contentsOf: out)
    }

    /// A tiny hand-built stored ZIP (CRCs zeroed; only for inspector tests).
    static func rawZip(names: [String], symlink: Bool = false) -> Data {
        var local = Data(), central = Data()
        for name in names {
            let n = Data(name.utf8)
            let offset = UInt32(local.count)
            local += cat([le32(0x0403_4b50), le16(20), le16(0), le16(0), le32(0), le32(0), le32(0), le32(0), le16(UInt16(n.count)), le16(0), n])
            let madeBy: UInt16 = symlink ? 0x0314 : 20
            let attrs: UInt32 = symlink ? 0o120777 << 16 : 0
            central += cat([le32(0x0201_4b50), le16(madeBy), le16(20), le16(0), le16(0), le32(0), le32(0), le32(0), le32(0),
                            le16(UInt16(n.count)), le16(0), le16(0), le16(0), le16(0), le32(attrs), le32(offset), n])
        }
        let eocd = cat([le32(0x0605_4b50), le16(0), le16(0), le16(UInt16(names.count)), le16(UInt16(names.count)),
                        le32(UInt32(central.count)), le32(UInt32(local.count)), le16(0)])
        return local + central + eocd
    }

    static func cat(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }

    // Protobuf encoding of length-delimited fields.
    static func varint(_ v: UInt64) -> Data {
        var v = v, out = Data()
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    static func field(_ n: Int, _ payload: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(payload.count)) + payload }

    /// A CRX3 signed with a fresh P-256 developer key (no publisher proof).
    static func crx3(zip: Data, tamper: Bool = false) throws -> (crx: Data, id: String) {
        let key = P256.Signing.PrivateKey()
        let spki = key.publicKey.derRepresentation
        let id = ChromeExtensionID.from(publicKey: spki)
        let crxID = Data(SHA256.hash(data: spki)).prefix(16)
        let signedHeader = field(1, Data(crxID))
        var signed = Data("CRX3 SignedData\0".utf8) + le32(UInt32(signedHeader.count)) + signedHeader + zip
        let sig = try key.signature(for: signed).derRepresentation
        if tamper { signed.removeAll() }
        let header = field(3, field(1, spki) + field(2, sig)) + field(10000, signedHeader)
        var body = zip
        if tamper { body[body.count - 1] ^= 0xff }
        return (Data("Cr24".utf8) + le32(3) + le32(UInt32(header.count)) + header + body, id)
    }

    /// A CRX2 signed with a fresh RSA-2048 key (SHA1 over the ZIP).
    static func crx2(zip: Data) throws -> (crx: Data, id: String) {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let pub = try #require(SecKeyCopyPublicKey(priv))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, nil)) as Data
        let spki = der(0x30, der(0x30, Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])) + der(0x03, Data([0]) + pkcs1))
        let sig = try #require(SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA1, zip as CFData, nil)) as Data
        let crx = Data("Cr24".utf8) + le32(2) + le32(UInt32(spki.count)) + le32(UInt32(sig.count)) + spki + sig + zip
        return (crx, ChromeExtensionID.from(publicKey: spki))
    }

    static func der(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        if body.count < 0x80 { out.append(UInt8(body.count)) } else {
            let bytes = withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init).drop { $0 == 0 }
            out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
        }
        return out + body
    }

    static let mv3: [String: String] = [
        "manifest.json": """
        {
          "manifest_version": 3,
          "name": "__MSG_extName__",
          "version": "1.2.3",
          "default_locale": "en",
          "description": "Aegis test extension",
          "permissions": ["storage", "tabs"],
          "host_permissions": ["*://*.example.com/*"],
          "background": { "service_worker": "background.js" },
          "action": { "default_title": "Test" },
          "content_scripts": [{ "matches": ["https://example.org/*"], "js": ["content.js"] }]
        }
        """,
        "_locales/en/messages.json": #"{ "extName": { "message": "Aegis Test" } }"#,
        "background.js": """
        chrome.runtime.onInstalled.addListener(() => {});
        const ns = (typeof chrome !== 'undefined' ? 'chrome' : '') + (typeof browser !== 'undefined' ? '+browser' : '');
        chrome.storage.local.set({ ns, at: Date.now() })
          .then(() => chrome.storage.local.get('ns'))
          .then((v) => chrome.tabs.create({ url: 'https://example.org/?ns=' + encodeURIComponent(v.ns) }))
          .catch((e) => chrome.tabs.create({ url: 'https://example.org/?error=' + encodeURIComponent(String(e)) }));
        """,
        "content.js": "document.documentElement.dataset.aegisTest = '1';",
        "_metadata/verified_contents.json": "[]",
    ]
}

// MARK: - CRX parsing

@Suite struct CRXPackageTests {
    @Test func parsesAndVerifiesCRX3() async throws {
        let zip = try await Fixture.zip(["manifest.json": "{}"])
        let (crx, id) = try Fixture.crx3(zip: zip)
        let pkg = try CRXPackage.parse(crx)
        #expect(pkg.format == .crx3)
        #expect(pkg.zip == zip)
        #expect(pkg.declaredID == id)
        try pkg.verify(expectedID: id, requirePublisherProof: false)
        #expect(throws: CRXError.missingPublisherSignature) { try pkg.verify(expectedID: id) }
        #expect(throws: CRXError.idMismatch(expected: String(repeating: "a", count: 32), actual: id)) {
            try pkg.verify(expectedID: String(repeating: "a", count: 32), requirePublisherProof: false)
        }
    }

    @Test func rejectsTamperedCRX3() async throws {
        let zip = try await Fixture.zip(["manifest.json": "{}"])
        let (crx, id) = try Fixture.crx3(zip: zip, tamper: true)
        let pkg = try CRXPackage.parse(crx)
        #expect(throws: CRXError.invalidSignature) { try pkg.verify(expectedID: id, requirePublisherProof: false) }
    }

    @Test func parsesAndVerifiesCRX2() async throws {
        let zip = try await Fixture.zip(["manifest.json": "{}"])
        let (crx, id) = try Fixture.crx2(zip: zip)
        let pkg = try CRXPackage.parse(crx)
        #expect(pkg.format == .crx2)
        #expect(pkg.zip == zip)
        #expect(pkg.declaredID == id)
        try pkg.verify(expectedID: id)
    }

    @Test func rejectsMalformed() {
        #expect(throws: CRXError.truncated) { try CRXPackage.parse(Data("Cr24".utf8)) }
        #expect(throws: CRXError.badMagic) { try CRXPackage.parse(Data("PK\u{3}\u{4}00000000".utf8)) }
        #expect(throws: CRXError.unsupportedVersion(4)) { try CRXPackage.parse(Data("Cr24".utf8) + Fixture.le32(4) + Fixture.le32(0)) }
        // Header length beyond the file.
        #expect(throws: CRXError.truncated) { try CRXPackage.parse(Data("Cr24".utf8) + Fixture.le32(3) + Fixture.le32(999)) }
        // Valid framing but payload isn't a ZIP.
        #expect(throws: CRXError.missingPayload) {
            try CRXPackage.parse(Data("Cr24".utf8) + Fixture.le32(3) + Fixture.le32(0) + Data(repeating: 0x41, count: 40))
        }
    }

    @Test func extensionIDFromKey() {
        #expect(ChromeExtensionID.isValid(ChromeExtensionID.from(publicKey: Data("x".utf8))))
        #expect(ChromeExtensionID.from(idBytes: [0x00, 0xff]) == "aapp")
    }
}

// MARK: - Web Store URLs

@Suite struct WebStoreURLTests {
    let ubo = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    @Test func parsesStoreURLs() {
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/detail/ublock-origin-lite/\(ubo)") == ubo)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/detail/ublock-origin-lite/\(ubo)?hl=en&pli=1") == ubo)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/detail/\(ubo)") == ubo)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chrome.google.com/webstore/detail/ublock-origin-lite/\(ubo)") == ubo)
        #expect(ChromeExtensionID.fromWebStoreURL(ubo) == ubo)
    }

    @Test func rejectsOtherURLs() {
        #expect(ChromeExtensionID.fromWebStoreURL("https://example.com/detail/x/\(ubo)") == nil)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/category/extensions") == nil)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/detail/x/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == nil)
        #expect(ChromeExtensionID.fromWebStoreURL("https://chromewebstore.google.com/detail/x/\(ubo.prefix(31))") == nil)
    }

    @Test func downloadURL() throws {
        let url = try ChromeWebStore.downloadURL(for: ubo).absoluteString
        #expect(url.hasPrefix("https://clients2.google.com/service/update2/crx?response=redirect&prodversion="))
        #expect(url.contains("acceptformat=crx2,crx3"))
        #expect(url.contains("x=id%3D\(ubo)%26"))
        #expect(url.hasSuffix("%26uc"))
        #expect(throws: ChromeWebStoreError.invalidExtensionID) { try ChromeWebStore.downloadURL(for: "nope") }
        #expect(ChromeWebStore.isStorePage(URL(string: "https://chromewebstore.google.com/detail/a/\(ubo)")!))
        #expect(!ChromeWebStore.isStorePage(URL(string: "https://example.com/")!))
    }
}

// MARK: - Manifest & installer

@Suite struct ManifestAndInstallerTests {
    @Test func readsLocalizedMV3Manifest() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.mv3, to: dir)
        let m = try ExtensionManifest.read(from: dir)
        #expect(m.name == "Aegis Test")
        #expect(m.version == "1.2.3")
        #expect(m.manifestVersion == 3)
        #expect(m.permissions == ["storage", "tabs"])
        #expect(m.hostPermissions == ["*://*.example.com/*"])
        #expect(m.contentScriptMatches == ["https://example.org/*"])
    }

    @Test func splitsMV2HostPermissions() throws {
        let json = #"{"manifest_version":2,"name":"Old","version":"1","permissions":["storage","<all_urls>","https://a.com/*"]}"#
        let m = try ExtensionManifest.parse(Data(json.utf8))
        #expect(m.permissions == ["storage"])
        #expect(m.hostPermissions == ["<all_urls>", "https://a.com/*"])
        #expect(throws: ExtensionInstallError.unsupportedManifestVersion(1)) {
            try ExtensionManifest.parse(Data(#"{"manifest_version":1,"name":"x"}"#.utf8))
        }
    }

    @Test func zipInspectorRejectsUnsafeArchives() throws {
        #expect(try ZIPInspector.validate(Fixture.rawZip(names: ["manifest.json", "js/a.js"])) == ["manifest.json", "js/a.js"])
        for bad in ["../evil", "/abs", "a/../../b", "a\\b", "./x"] {
            #expect(throws: ExtensionInstallError.self) { try ZIPInspector.validate(Fixture.rawZip(names: [bad])) }
        }
        #expect(throws: ExtensionInstallError.self) { try ZIPInspector.validate(Fixture.rawZip(names: ["link"], symlink: true)) }
        #expect(throws: ExtensionInstallError.self) { try ZIPInspector.validate(Fixture.rawZip(names: ["a", "A"])) }
    }

    @Test func installsAtomicallyAndStripsMetadata() async throws {
        let root = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ExtensionInstaller(root: root)
        let id = String(repeating: "b", count: 32)
        let manifest = try await installer.install(zip: try await Fixture.zip(Fixture.mv3), id: id)
        #expect(manifest.name == "Aegis Test")
        let dir = installer.directory(for: id)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "_metadata").path))
        // Reinstall replaces in place; no staging folders left behind.
        try await installer.install(zip: try await Fixture.zip(Fixture.mv3), id: id)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging") }
        #expect(leftovers.isEmpty)
    }

    @Test func permissionSummary() {
        let r = ExtensionPermissionRequest(extensionID: "x", name: "X", permissions: ["tabs", "storage"], matchPatterns: ["<all_urls>"])
        #expect(r.summary.first == "Read and change all your data on all websites")
        #expect(r.summary.contains("Read your browsing history"))
        #expect(ExtensionPermissionRequest.host(ofPattern: "*://*.example.com/*") == "example.com")
    }
}

// MARK: - WebKit integration

@Suite(.serialized) @MainActor struct ExtensionHostTests {
    @Test func delegateImplementsExpectedSelectors() {
        let host = ExtensionHost(root: FileManager.default.temporaryDirectory.appending(path: "aegis-sel-\(UUID())"), persistent: false)
        for sel in [
            "webExtensionController:openWindowsForExtensionContext:",
            "webExtensionController:focusedWindowForExtensionContext:",
            "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:",
            "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:",
            "webExtensionController:openOptionsPageForExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:",
            "webExtensionController:didUpdateAction:forExtensionContext:",
            "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:",
        ] {
            #expect(host.responds(to: NSSelectorFromString(sel)), "missing \(sel)")
        }
        let tab = ExtensionTabAdapter(webView: { nil }, isSelected: { true }, window: { nil }, activate: {}, close: {})
        for sel in ["webViewForWebExtensionContext:", "activateForWebExtensionContext:completionHandler:",
                    "closeForWebExtensionContext:completionHandler:", "goBackForWebExtensionContext:completionHandler:",
                    "reloadFromOrigin:forWebExtensionContext:completionHandler:", "indexInWindowForWebExtensionContext:"] {
            #expect(tab.responds(to: NSSelectorFromString(sel)), "tab missing \(sel)")
        }
        let window = ExtensionWindowAdapter(tabs: { [] }, activeTab: { nil }, frame: { .zero }, focus: {})
        for sel in ["tabsForWebExtensionContext:", "activeTabForWebExtensionContext:", "focusForWebExtensionContext:completionHandler:",
                    "isPrivateForWebExtensionContext:", "frameForWebExtensionContext:"] {
            #expect(window.responds(to: NSSelectorFromString(sel)), "window missing \(sel)")
        }
    }

    @Test func loadsTinyMV3ExtensionAfterConsent() async throws {
        let root = try Fixture.tempDir()
        let src = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        try Fixture.write(Fixture.mv3, to: src)

        let host = ExtensionHost(root: root, persistent: false)
        let installed = try await host.installUnpacked(from: src)
        #expect(installed.name == "Aegis Test")
        #expect(!installed.consented)
        // Not loaded before consent.
        #expect(host.context(for: installed.id) == nil)

        let pending = try #require(host.pendingPermissions(for: installed.id))
        print("[ext] pending permissions:", pending.permissions, "patterns:", pending.matchPatterns)
        #expect(pending.permissions.contains("storage"))
        #expect(pending.matchPatterns.contains("*://*.example.com/*"))
        #expect(pending.matchPatterns.contains("https://example.org/*"))

        try host.grant(ExtensionPermissionGrant(pending))
        let ctx = try #require(host.context(for: installed.id))
        #expect(ctx.isLoaded)
        #expect(ctx.uniqueIdentifier == installed.id)
        #expect(ctx.hasPermission(.storage))
        #expect(ctx.hasAccess(to: URL(string: "https://www.example.com/page")!))
        #expect(!ctx.hasAccess(to: URL(string: "https://evil.test/")!))
        #expect(ctx.hasInjectedContent(for: URL(string: "https://example.org/x")!))
        #expect(host.pendingPermissions(for: installed.id) == nil)
        let ext = try #require(host.webExtension(for: installed.id))
        print("[ext] WKWebExtension.errors:", ext.errors.map(\.localizedDescription))
        print("[ext] context.errors:", ctx.errors.map(\.localizedDescription))
        #expect(host.errors(for: installed.id).isEmpty)

        // The background worker round-trips chrome.storage.local, then calls
        // chrome.tabs.create — which must arrive at our openTab callback.
        var opened: URL?
        host.openTab = { req in opened = req.url; return nil }
        do {
            try await ctx.loadBackgroundContent()
        } catch {
            print("[ext] loadBackgroundContent error:", error)
        }
        for _ in 0..<60 where opened == nil { try await Task.sleep(for: .milliseconds(250)) }
        print("[ext] background worker opened:", opened?.absoluteString ?? "nothing")
        print("[ext] context.errors after background:", ctx.errors.map(\.localizedDescription))
        let query = opened.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(query?.first?.name == "ns", "background worker failed: \(opened?.absoluteString ?? "no tab opened")")
        #expect(query?.first?.value == "chrome+browser")

        // Persisted grants survive a fresh host on the same root.
        let reborn = ExtensionHost(root: root, persistent: false)
        let record = try #require(reborn.record(for: installed.id))
        #expect(record.consented)
        #expect(record.grantedPermissions.contains("storage"))

        try host.setEnabled(false, for: installed.id)
        #expect(!ctx.isLoaded)
        try host.setEnabled(true, for: installed.id)
        #expect(ctx.isLoaded)
        try await host.uninstall(id: installed.id)
        #expect(!host.isInstalled(installed.id))
        #expect(!FileManager.default.fileExists(atPath: host.installer.directory(for: installed.id).path))
    }

    @Test func installsSyntheticCRX3EndToEnd() async throws {
        let root = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (crx, id) = try Fixture.crx3(zip: try await Fixture.zip(Fixture.mv3))
        let host = ExtensionHost(root: root, persistent: false)
        // Store installs demand the publisher co-signature.
        await #expect(throws: CRXError.missingPublisherSignature) { try await host.install(crx: crx, id: id) }
        let installed = try await host.install(crx: crx, id: id, requirePublisherProof: false)
        #expect(installed.id == id)
        #expect(installed.version == "1.2.3")
        try host.grant(ExtensionPermissionGrant(extensionID: id, permissions: ["storage"], matchPatterns: []))
        #expect(host.context(for: id)?.isLoaded == true)
        // Host pattern not granted → no access.
        #expect(host.context(for: id)?.hasAccess(to: URL(string: "https://example.com/")!) == false)
    }

    @Test func tabBridgeAndDelegateOpenTab() async throws {
        let root = try Fixture.tempDir()
        let src = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        try Fixture.write(Fixture.mv3, to: src)
        let host = ExtensionHost(root: root, persistent: false)
        let installed = try await host.installUnpacked(from: src)
        try host.grant(ExtensionPermissionGrant(try #require(host.pendingPermissions(for: installed.id))))
        let ctx = try #require(host.context(for: installed.id))

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        host.configure(config)
        #expect(config.webExtensionController === host.controller)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

        var tabs: [ExtensionTabAdapter] = []
        var window: ExtensionWindowAdapter!
        let owner = NSObject()
        let tab = host.tabAdapter(for: owner) {
            ExtensionTabAdapter(webView: { view }, title: { "T" }, url: { URL(string: "https://example.org/") },
                                isSelected: { true }, window: { window }, activate: {}, close: {})
        }
        #expect(host.tabAdapter(for: owner) { fatalError("must reuse") } === tab)
        tabs = [tab]
        window = ExtensionWindowAdapter(tabs: { tabs }, activeTab: { tabs.first }, frame: { .zero }, focus: {})
        host.openWindows = { [window!] }
        host.didOpen(window: window)
        host.didOpen(tab: tab)
        host.didActivate(tab: tab)
        #expect(ctx.openTabs.contains(AnyHashable(tab)))
        #expect(ctx.openWindows.first === window)
        #expect(ctx.focusedWindow === window)
        let action = try #require(host.action(for: installed.id, tab: tab))
        #expect(action.label == "Test")
        #expect(!action.presentsPopup)
        host.didClose(tab: tab, owner: owner)
        #expect(host.existingTabAdapter(for: owner) == nil)
        #expect(!ctx.openTabs.contains(AnyHashable(tab)))
    }
}

@Suite @MainActor struct WebTabBridgeTests {
    @Test func adapterWrapsWebTabAndDiffsChanges() throws {
        let root = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ExtensionHost(root: root, persistent: false)
        let context = ProfileContext(profile: Profile(name: "T"), ephemeral: true, policy: nil, settings: PrivacySettings())
        let tab = WebTab(id: TabID(), context: context)
        let view = tab.wake(url: nil, interactionState: nil)
        let adapter = host.adapter(for: tab, isSelected: { true }, window: { nil }, activate: {}, close: {})
        #expect(host.adapter(for: tab, isSelected: { false }, window: { nil }, activate: {}, close: {}) === adapter)
        #expect(adapter.webView() === view)
        #expect(adapter.isPrivate())
        host.webTabDidChange(tab) // first call only records a snapshot
        host.webTabDidClose(tab)
        #expect(host.existingTabAdapter(for: tab) == nil)
    }
}

// MARK: - Real extensions (network; opt-in with AEGIS_NETWORK_TESTS=1)

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AEGIS_NETWORK_TESTS"] != nil))
@MainActor struct RealExtensionTests {
    @Test(arguments: [
        ("uBlock Origin Lite", "ddkjiahejlhfcafbddmgiahcphecmpfh"),
        ("Dark Reader", "eimadpbcbfnmbkopoojfekhnkhdbieeh"),
        ("Bitwarden", "nngceckbapebfimnlniiiahkandclblb"),
    ])
    func downloadsVerifiesAndLoads(name: String, id: String) async throws {
        let root = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ExtensionHost(root: root, persistent: false)
        let crx = try await ChromeWebStore.downloadCRX(id: id)
        let pkg = try CRXPackage.parse(crx)
        print("[real] \(name): \(crx.count) bytes, format \(pkg.format), declared id \(pkg.declaredID ?? "nil")")
        let installed = try await host.install(crx: crx, id: id)
        let pending = host.pendingPermissions(for: id)
        print("[real] \(name) \(installed.version) MV\(installed.manifestVersion) permissions:", pending?.permissions ?? [], "patterns:", pending?.matchPatterns ?? [])
        try host.grant(ExtensionPermissionGrant(try #require(pending)))
        let ctx = try #require(host.context(for: id))
        #expect(ctx.isLoaded)
        try await Task.sleep(for: .seconds(4))
        print("[real] \(name) errors:", host.errors(for: id))
        let ext = try #require(host.webExtension(for: id))
        let requested = Set(ext.manifest["permissions"] as? [String] ?? [])
        let known = Set(ExtensionCompatibility.supportedPermissions)
        print("[real] \(name) manifest permissions WebKit doesn't know:", requested.subtracting(known).sorted())
        if id == "ddkjiahejlhfcafbddmgiahcphecmpfh" {
            // Does the DNR ruleset actually block in a web view wired to the controller?
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            host.configure(config)
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            let tab = ExtensionTabAdapter(webView: { view }, isSelected: { true }, window: { nil }, activate: {}, close: {})
            host.didOpen(tab: tab)
            view.load(URLRequest(url: URL(string: "https://example.com/")!))
            for _ in 0..<40 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(250)) }
            try await Task.sleep(for: .seconds(2))
            let js = "try { await fetch('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js', {mode: 'no-cors'}); return 'loaded'; } catch (e) { return 'blocked: ' + e; }"
            let ad = try await view.callAsyncJavaScript(js, contentWorld: .page) as? String
            let ok = try await view.callAsyncJavaScript(js.replacingOccurrences(of: "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", with: "https://www.iana.org/favicon.ico"), contentWorld: .page) as? String
            print("[real] uBOL DNR: ad request ->", ad ?? "nil", "| control request ->", ok ?? "nil")
        }
        print("[real] \(name) hasBackground:", ext.hasBackgroundContent, "hasInjected:", ext.hasInjectedContent,
              "DNR rules:", ext.hasContentModificationRules, "options:", ext.hasOptionsPage)
    }
}
