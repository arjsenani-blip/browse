import Foundation

public enum ChromeWebStoreError: Error, Equatable, Sendable {
    case invalidExtensionID
    case downloadFailed(status: Int)
    case disallowedRedirect
    case tooLarge
}

/// Talks to Google's update service. Only contacted when the user installs
/// (or, later, explicitly checks for updates); never in the background.
public enum ChromeWebStore {
    public static let storeHost = "chromewebstore.google.com"
    /// Chrome version we claim; extensions with `minimum_chrome_version` above
    /// this get rejected by the update service. Bump with Chrome stable.
    public static let prodVersion = "142.0.7444.0"
    static let maxPackageSize = 256 * 1024 * 1024
    static let allowedHosts: Set<String> = ["clients2.google.com", "clients2.googleusercontent.com"]

    /// True for Web Store pages (new and legacy) — where the lead shows "Add to Aegis".
    public static func isStorePage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == storeHost || (host == "chrome.google.com" && url.path().hasPrefix("/webstore"))
    }

    public static func downloadURL(for id: String) throws -> URL {
        guard ChromeExtensionID.isValid(id) else { throw ChromeWebStoreError.invalidExtensionID }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "clients2.google.com"
        c.path = "/service/update2/crx"
        // `x` is itself a query string, so its '=' and '&' must be percent-encoded.
        c.percentEncodedQuery = "response=redirect&prodversion=\(prodVersion)&acceptformat=crx2,crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc"
        guard let url = c.url else { throw ChromeWebStoreError.invalidExtensionID }
        return url
    }

    static func isAllowedDestination(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && allowedHosts.contains(url.host() ?? "")
    }

    /// Downloads the CRX bytes. Ephemeral session: no cookies, no cache, no
    /// credentials; redirects only to Google's CRX hosts.
    public static func downloadCRX(id: String) async throws -> Data {
        let url = try downloadURL(for: id)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 120))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw ChromeWebStoreError.downloadFailed(status: 0) }
        guard http.statusCode == 200 else { throw ChromeWebStoreError.downloadFailed(status: http.statusCode) }
        guard let final = http.url, isAllowedDestination(final) else { throw ChromeWebStoreError.disallowedRedirect }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxPackageSize else { throw ChromeWebStoreError.tooLarge }
        // The service answers 200 with an empty body for unknown/unavailable IDs.
        guard size > 0 else { throw ChromeWebStoreError.downloadFailed(status: 204) }
        return try Data(contentsOf: file)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, ChromeWebStore.isAllowedDestination(url) else { return nil }
            return request
        }
    }
}
