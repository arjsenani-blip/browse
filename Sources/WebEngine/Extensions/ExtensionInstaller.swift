import Foundation

public enum ExtensionInstallError: Error, Equatable, Sendable {
    case unsafeArchive(String)
    case unzipFailed(Int32)
    case missingManifest
    case invalidManifest(String)
    case unsupportedManifestVersion(Int)
}

/// The parts of `manifest.json` the UI needs before WebKit is involved
/// (consent sheet, extension list). WebKit re-parses it authoritatively.
public struct ExtensionManifest: Sendable, Equatable {
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var description: String?
    /// API permissions (`storage`, `tabs`, …).
    public var permissions: [String]
    public var optionalPermissions: [String]
    /// Host match patterns: MV3 `host_permissions`, MV2 host entries in `permissions`.
    public var hostPermissions: [String]
    /// Union of `content_scripts[].matches`.
    public var contentScriptMatches: [String]

    public static func read(from directory: URL) throws -> ExtensionManifest {
        let url = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw ExtensionInstallError.missingManifest }
        return try parse(data, localeDirectory: directory)
    }

    public static func parse(_ data: Data, localeDirectory: URL? = nil) throws -> ExtensionManifest {
        // Chrome tolerates a UTF-8 BOM in manifests.
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ExtensionInstallError.invalidManifest("not a JSON object")
        }
        guard let mv = json["manifest_version"] as? Int else { throw ExtensionInstallError.invalidManifest("manifest_version") }
        guard mv == 2 || mv == 3 else { throw ExtensionInstallError.unsupportedManifestVersion(mv) }
        guard let rawName = json["name"] as? String else { throw ExtensionInstallError.invalidManifest("name") }
        let messages = localeDirectory.flatMap { loadMessages(in: $0, defaultLocale: json["default_locale"] as? String) } ?? [:]
        func localize(_ s: String) -> String {
            guard s.hasPrefix("__MSG_"), s.hasSuffix("__"), s.count > 8 else { return s }
            let key = String(s.dropFirst(6).dropLast(2)).lowercased()
            return messages[key] ?? s
        }
        let strings = { (key: String) in (json[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        let isHost = { (s: String) in s == "<all_urls>" || s.contains("://") }
        let perms = strings("permissions")
        let hosts = mv == 3 ? strings("host_permissions") : perms.filter(isHost)
        let matches = ((json["content_scripts"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["matches"] as? [String]) ?? [] }
        return ExtensionManifest(
            name: localize(rawName),
            version: json["version"] as? String ?? "0",
            manifestVersion: mv,
            description: (json["description"] as? String).map(localize),
            permissions: perms.filter { !isHost($0) },
            optionalPermissions: strings("optional_permissions").filter { !isHost($0) },
            hostPermissions: hosts,
            contentScriptMatches: Array(NSOrderedSet(array: matches)) as? [String] ?? matches
        )
    }

    /// `_locales/<default_locale>/messages.json`, keys lowercased (Chrome matches case-insensitively).
    static func loadMessages(in directory: URL, defaultLocale: String?) -> [String: String]? {
        guard let locale = defaultLocale else { return nil }
        let url = directory.appending(path: "_locales").appending(path: locale).appending(path: "messages.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in json { if let m = (v as? [String: Any])?["message"] as? String { out[k.lowercased()] = m } }
        return out
    }
}

/// Unpacks verified packages into `<root>/<id>/` atomically.
public struct ExtensionInstaller: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Aegis", directoryHint: .isDirectory)
            .appending(path: "Extensions", directoryHint: .isDirectory)
    }

    public init(root: URL = ExtensionInstaller.defaultRoot) { self.root = root }

    public func directory(for id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// Validates the ZIP, extracts it with `ditto` into a staging folder on the
    /// same volume, strips `_metadata` (Chrome's signed hashes, unused here),
    /// reads the manifest, then swaps the folder into place.
    @discardableResult
    public func install(zip: Data, id: String) async throws -> ExtensionManifest {
        guard ChromeExtensionID.isValid(id) else { throw ChromeWebStoreError.invalidExtensionID }
        try ZIPInspector.validate(zip)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appending(path: "package.zip")
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        try zip.write(to: archive)
        try await Self.ditto(["-x", "-k", archive.path, unpacked.path])
        return try place(unpacked, id: id)
    }

    /// Installs an already-unpacked extension folder (developer "load unpacked").
    @discardableResult
    public func install(directory source: URL, id: String) throws -> ExtensionManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        try fm.copyItem(at: source, to: unpacked)
        return try place(unpacked, id: id)
    }

    private func place(_ unpacked: URL, id: String) throws -> ExtensionManifest {
        let fm = FileManager.default
        try? fm.removeItem(at: unpacked.appending(path: "_metadata"))
        try Self.rejectLinks(in: unpacked)
        let manifest = try ExtensionManifest.read(from: unpacked)
        let target = directory(for: id)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: unpacked)
        } else {
            try fm.moveItem(at: unpacked, to: target)
        }
        return manifest
    }

    public func remove(id: String) throws {
        let dir = directory(for: id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    static func ditto(_ args: [String]) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        guard status == 0 else { throw ExtensionInstallError.unzipFailed(status) }
    }

    /// Belt and braces after ZIPInspector: no symlinks anywhere in the tree.
    static func rejectLinks(in dir: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: Set(keys)).isSymbolicLink) == true {
            throw ExtensionInstallError.unsafeArchive("symlink \(url.lastPathComponent)")
        }
    }
}

/// Reads the ZIP central directory without extracting, and rejects archives
/// that could escape the target folder or exhaust disk: absolute paths, `..`,
/// backslashes, NULs, symlinks, duplicate names, > 20k entries, > 256 MB
/// uncompressed, ZIP64.
enum ZIPInspector {
    static let maxEntries = 20_000
    static let maxTotalSize: UInt64 = 256 * 1024 * 1024

    @discardableResult
    static func validate(_ input: Data) throws -> [String] {
        let zip = Data(input)
        guard zip.count >= 22 else { throw ExtensionInstallError.unsafeArchive("too small") }
        var eocd = -1
        let lowest = max(0, zip.count - 22 - 0xFFFF)
        var i = zip.count - 22
        while i >= lowest {
            if zip.u32(at: i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ExtensionInstallError.unsafeArchive("no end of central directory") }
        let count = Int(zip.u16(at: eocd + 10))
        let cdSize = Int(zip.u32(at: eocd + 12)), cdOffset = Int(zip.u32(at: eocd + 16))
        guard count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else { throw ExtensionInstallError.unsafeArchive("zip64") }
        guard count <= maxEntries, cdOffset + cdSize <= eocd else { throw ExtensionInstallError.unsafeArchive("bad central directory") }
        var names: [String] = [], seen = Set<String>(), total: UInt64 = 0, p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= eocd, zip.u32(at: p) == 0x0201_4b50 else { throw ExtensionInstallError.unsafeArchive("bad entry") }
            let madeBy = zip.u16(at: p + 4)
            let size = UInt64(zip.u32(at: p + 24))
            let nameLen = Int(zip.u16(at: p + 28)), extraLen = Int(zip.u16(at: p + 30)), commentLen = Int(zip.u16(at: p + 32))
            let attrs = zip.u32(at: p + 38)
            guard p + 46 + nameLen <= eocd else { throw ExtensionInstallError.unsafeArchive("bad entry") }
            let name = String(decoding: zip.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.isEmpty || name.hasPrefix("/") || name.contains("\\") || name.contains("\0")
                || parts.contains("..") || parts.contains(".") || parts.dropLast().contains("") {
                throw ExtensionInstallError.unsafeArchive("path \(name)")
            }
            if madeBy >> 8 == 3, (attrs >> 16) & 0o170000 == 0o120000 { throw ExtensionInstallError.unsafeArchive("symlink \(name)") }
            guard seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ExtensionInstallError.unsafeArchive("duplicate \(name)")
            }
            guard size != 0xFFFF_FFFF else { throw ExtensionInstallError.unsafeArchive("zip64") }
            total += size
            guard total <= maxTotalSize else { throw ExtensionInstallError.unsafeArchive("too large") }
            names.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
        return names
    }
}
