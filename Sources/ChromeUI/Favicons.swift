import AppKit

/// Favicons fetched from the site itself (never a third-party favicon
/// service), cached in memory and on disk by host.
@MainActor
public final class Favicons {
    public static let shared = Favicons()
    private var memory: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private var waiters: [String: [(NSImage?) -> Void]] = [:]
    private let folder: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = base.appending(path: "Aegis/Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func cached(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        if let image = memory[host] { return image }
        let file = folder.appending(path: host + ".png")
        if let image = NSImage(contentsOf: file) { memory[host] = image; return image }
        return nil
    }

    public func load(for url: URL?, completion: @escaping (NSImage?) -> Void) {
        guard let url, let host = url.host(), let scheme = url.scheme, scheme.hasPrefix("http") else { return completion(nil) }
        if let image = cached(for: url) { return completion(image) }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        parts.path = "/favicon.ico"
        // A host that can't form a URL (malformed or odd IPv6) gets no icon rather than a crash.
        guard let icon = parts.url else { return completion(nil) }
        waiters[host, default: []].append(completion)
        guard !inflight.contains(host) else { return }
        inflight.insert(host)
        let file = folder.appending(path: host + ".png")
        let session = self.session
        Task.detached(priority: .utility) {
            var image: NSImage?
            if let (data, response) = try? await session.data(from: icon),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = NSImage(data: data), decoded.isValid {
                image = decoded
                if let tiff = decoded.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: file)
                }
            }
            await MainActor.run { [image] in
                self.inflight.remove(host)
                if let image { self.memory[host] = image }
                self.waiters.removeValue(forKey: host)?.forEach { $0(image) }
            }
        }
    }

    /// A neutral placeholder for sites without an icon: the system globe,
    /// tinted secondary so it reads in light and dark.
    public static func placeholder(hue: Double? = nil) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [NSColor.secondaryLabelColor]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }
}
