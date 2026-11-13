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
        folder = base.appending(path: "Vane/Favicons", directoryHint: .isDirectory)
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

    /// Weakly keyed by the image: an ObjectIdentifier key outlives its image,
    /// grows without bound, and hands a freed icon's answer to whichever new
    /// image reuses the address.
    private static let darkness = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    /// True for icons that are mostly dark ink (they need a light plate on dark
    /// themes). The globe placeholder is tinted for both and never gets one
    /// (it used to read as "dark" and showed as a blank white tile).
    public static func isDark(_ image: NSImage) -> Bool {
        if image === placeholderImage { return false }
        if let known = darkness.object(forKey: image) { return known.boolValue }
        var dark = false
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = 16, h = 16
            var px = [UInt8](repeating: 0, count: w * h * 4)
            if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                var lum = 0.0, weight = 0.0
                for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 40 {
                    let a = Double(px[i + 3]) / 255
                    lum += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255 / a
                    weight += 1
                }
                dark = weight > 8 && lum / weight < 0.22
            }
        }
        darkness.setObject(NSNumber(value: dark), forKey: image)
        return dark
    }

    /// A neutral placeholder for sites without an icon: the system globe,
    /// tinted secondary so it reads in light and dark. One shared instance.
    public static func placeholder(hue: Double? = nil) -> NSImage { placeholderImage }

    private static let placeholderImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [NSColor.secondaryLabelColor]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }()
}
