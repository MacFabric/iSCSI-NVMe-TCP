import Foundation
import Testing
@testable import NVMeMockTarget
@testable import NVMeKit

/// A target that accepts the connection and then says nothing. `taskTimeout`
/// covers I/O on an established connection only, so before
/// `SessionPolicy.loginTimeout` this hung the attach — and every recovery
/// attempt behind it — for as long as the peer stayed quiet.
@Suite("Integration: login and bring-up deadlines", .timeLimit(.minutes(1)))
struct LoginDeadlineTests {
    /// Hands out connections whose far end never answers, and keeps those ends
    /// so a test can see the initiator closed them.
    actor SilentPeers {
        private(set) var peers: [MemoryPipe] = []

        func makeTransport() -> any ConnectionTransport {
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            peers.append(targetSide)
            return initiatorSide
        }

        /// True once every peer has read to EOF — the initiator closed it,
        /// which is what ends an abandoned login instead of leaking it.
        func allClosed() async throws -> Bool {
            for peer in peers {
                while let chunk = try await peer.receive() { _ = chunk }
            }
            return !peers.isEmpty
        }
    }

    private func policy(loginTimeout: Duration = .milliseconds(200), attempts: Int = 2) -> SessionPolicy {
        var policy = testPolicy(retries: 1, recoveryAttempts: attempts)
        policy.loginTimeout = loginTimeout
        return policy
    }

    @Test func anNVMeControllerThatNeverSendsICRespTimesOut() async throws {
        let silent = SilentPeers()
        let controller = NVMeController(config: testControllerConfig(), policy: policy()) {
            await silent.makeTransport()
        }
        await #expect(throws: DeadlineError.timedOut) { try await controller.activate() }
        #expect(try await silent.allClosed())
    }

    @Test func anNVMeControllerThatStallsAfterConnectTimesOut() async throws {
        // ICResp, Fabrics Connect and the property commands are answered;
        // Identify, the first admin command, never is.
        var config = MockNVMeConfig()
        config.faults.stallCommands = true
        let fleet = NVMeFleet(config: config)
        let controller = NVMeController(config: testControllerConfig(), policy: policy()) {
            await fleet.makeTransport()
        }
        await #expect(throws: DeadlineError.timedOut) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func nvmeDiscoveryAgainstASilentPortalTimesOut() async throws {
        let silent = SilentPeers()
        await #expect(throws: DeadlineError.timedOut) {
            _ = try await NVMeDiscovery.getLogPage(
                transport: await silent.makeTransport(), host: testHost,
                timeout: .milliseconds(200))
        }
        #expect(try await silent.allClosed())
    }
}
