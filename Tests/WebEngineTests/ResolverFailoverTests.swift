import Foundation
import Testing
@testable import WebEngine

@Suite struct ResolverFailoverTests {
    @Test func repeatedConnectFailuresMoveToABackupResolver() {
        let engine = ProxyEngine(resolver: .mullvad, expectedAuthorization: nil)
        engine.queue.sync {
            engine.recordUpstream(success: false)
            engine.recordUpstream(success: true)          // a success resets the run
            engine.recordUpstream(success: false)
            engine.recordUpstream(success: false)
        }
        #expect(engine.queue.sync { engine.usingBackupResolver } == false)
        engine.queue.sync { engine.recordUpstream(success: false) }
        #expect(engine.queue.sync { engine.usingBackupResolver })
    }

    @Test func backupsStayEncryptedAndOffHasNone() {
        #expect(ProxyEngine.backup(for: .mullvad) == .quad9)
        #expect(ProxyEngine.backup(for: .quad9) == .cloudflare)
        #expect(ProxyEngine.backup(for: .off) == nil)
    }
}
