import Foundation
import Testing
@testable import iSCSIDaemon
@testable import InitiatorShared
@testable import iSCSIKit
import iSCSIMockTarget

/// Login redirects (RFC 7143 §11.13.5, status class 1) as the daemon makes
/// them. The session-level behaviour is iSCSIKit's own suite; what is tested
/// here is that the daemon's connect carries the target's interface pin.
@Suite("Integration: login redirects through the daemon", .timeLimit(.minutes(1)))
struct LoginRedirectTests {

    /// Which portal each connect was for: "home" for the configured portal,
    /// "host:port" for a redirect.
    final class ConnectLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    static let member = "10.0.0.2:3261,1"

    static func redirecting(temporary: Bool, to address: String = member) -> MockTargetConfig {
        var config = MockTargetConfig()
        config.faults.redirectTo = address
        config.faults.redirectIsTemporary = temporary
        return config
    }

    // MARK: Through the daemon

    /// The redirect connect is the daemon's to make, with the target's
    /// interface pin: a pinned target that followed a redirect over whatever
    /// interface macOS chose would quietly undo the pin.
    @Test("the daemon follows a redirect over the same interface pin")
    func daemonFollowsRedirectWithPin() async throws {
        let calls = ConnectLog()
        let harnesses = HarnessBox()
        defer { harnesses.cancelAll() }
        let disk = RAMDisk()
        let pinned = InterfaceBinding(name: "en18", fallback: false)
        let core = DaemonCore(initiatorName: "iqn.test:initiator", policy: testPolicy(),
                              hostIdentity: testHost) { host, port, binding in
            calls.add("\(host):\(port) via \(binding?.name ?? "routing")")
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let config = host == "group" ? Self.redirecting(temporary: true) : MockTargetConfig()
            let target = MockTarget(config: config, disk: disk, transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }

        let handle = try await core.login(host: "group", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        #expect(calls.all == ["group:3260 via en18", "10.0.0.2:3261 via en18"])
        try await core.logout(handle)
    }
}
