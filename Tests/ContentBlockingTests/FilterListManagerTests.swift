import Foundation
import Testing
@testable import ContentBlocking

final class MockFetcher: FilterFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let respond: @Sendable (URLRequest) -> (Int, Data, [String: String])

    init(respond: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])) { self.respond = respond }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, data, headers) = respond(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

@Suite struct FilterListManagerTests {
    let validList = Data(("[Adblock Plus 2.0]\n! Title: Test\n" + String(repeating: "||ads.example^\n", count: 200)).utf8)

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aegis-flm-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func bundledListsPresent() {
        let manager = FilterListManager(directory: tempDir(), fetcher: MockFetcher { _ in (500, Data(), [:]) })
        let names = manager.bundledListURLs().map(\.lastPathComponent)
        #expect(names.contains("starter.txt"))
        #expect(names.contains("easylist.txt"))
        #expect(names.contains("easyprivacy.txt"))
        #expect(!names.contains { $0.hasPrefix("LICENSE") })
        #expect(manager.activeListURLs().count == 3)
    }

    @Test func updateUsesETagAndRespectsInterval() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = validList
        let fetcher = MockFetcher { req in
            if req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return (304, Data(), [:]) }
            return (200, list, ["ETag": "\"v1\""])
        }
        let manager = FilterListManager(directory: dir, fetcher: fetcher)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let first = await manager.updateIfNeeded(now: t0)
        #expect(Set(first.updated) == ["easylist.txt", "easyprivacy.txt"])
        #expect(manager.activeListURLs().filter { $0.path.hasPrefix(dir.path) }.count == 2)
        for req in fetcher.requests {
            #expect(req.url?.scheme == "https")
            #expect(req.allHTTPHeaderFields?.isEmpty ?? true)
            #expect(req.httpShouldHandleCookies == false)
        }

        let second = await manager.updateIfNeeded(now: t0.addingTimeInterval(3600))
        #expect(second.skippedRecentlyChecked.count == 2)
        #expect(fetcher.requests.count == 2)

        // A new manager reads persisted metadata and revalidates with the ETag after 24h.
        let manager2 = FilterListManager(directory: dir, fetcher: fetcher)
        let third = await manager2.updateIfNeeded(now: t0.addingTimeInterval(25 * 3600))
        #expect(third.notModified.count == 2)
        #expect(fetcher.requests.suffix(2).allSatisfy { $0.allHTTPHeaderFields == ["If-None-Match": "\"v1\""] })
    }

    @Test func rejectsGarbageAndKeepsOldList() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetcher = MockFetcher { _ in (200, Data("<html>captive portal</html>".utf8), [:]) }
        let manager = FilterListManager(directory: dir, fetcher: fetcher)
        let outcome = await manager.updateIfNeeded(now: Date())
        #expect(outcome.failed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("easylist.txt").path))
        // Failure backoff: no immediate retry.
        let again = await manager.updateIfNeeded(now: Date().addingTimeInterval(60))
        #expect(again.skippedRecentlyChecked.count == 2)
    }

    @Test func disallowedHostsAreDropped() {
        let manager = FilterListManager(
            directory: tempDir(),
            remoteLists: [.init(name: "evil.txt", url: URL(string: "https://evil.example/list.txt")!),
                          .init(name: "plain.txt", url: URL(string: "http://easylist.to/easylist/easylist.txt")!),
                          .init(name: "fanboy.txt", url: URL(string: "https://secure.fanboy.co.uk/fanboy-annoyance.txt")!)],
            fetcher: MockFetcher { _ in (500, Data(), [:]) })
        #expect(manager.remoteLists.map(\.name) == ["fanboy.txt"])
    }
}
