import Foundation
import Synchronization
import Testing
@testable import NVMeKit
@testable import NVMeMockTarget

@Suite("Read logging", .timeLimit(.minutes(1)))
struct NVMeReadLoggingTests {
    @Test(arguments: [false, true])
    func chunkedReadsCorrelateTransportAndFunctionLogs(debug: Bool) async throws {
        let lines = Mutex<[String]>([])
        let ids = Mutex<[UUID]>([])
        let fleet = NVMeFleet()
        let sink: @Sendable (String) -> Void = { line in lines.withLock { $0.append(line) } }
        let config = testControllerConfig { $0.debugLog = sink }
        let controller = NVMeController(config: config, policy: testPolicy()) {
            let id = UUID()
            ids.withLock { $0.append(id) }
            return NVMeTracingTransport(await fleet.makeTransport(),
                                        level: debug ? .debug : .useful,
                                        connectionID: id, sink: sink)
        }
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: 1, maxTransferBytes: 4096)
        #expect(try await device.read(offset: 8192, length: 12288) == Data(count: 12288))
        try await controller.logout()
        await fleet.shutdown()

        let output = lines.withLock { $0 }
        let connections = ids.withLock { $0 }
        #expect(connections.count == 2)
        let io = try #require(connections.last).uuidString
        for lba in 2...4 {
            #expect(output.contains { $0.contains("NVMeBlockDevice.readChunk") && $0.contains("lba=\(lba)") })
            #expect(output.contains { $0.contains("NVMeQueue.submit") && $0.contains("connection=\(io)") && $0.contains("lba=\(lba)") })
        }
        #expect(output.filter { $0.contains("NVMeBlockDevice.readChunk") && $0.contains("finished") && $0.contains("connection=\(io)") && $0.contains("receivedBytes=4096") }.count == 3)
        #expect(output.contains { $0.contains("connection=\(io)") && $0.contains("← cid=") && $0.contains("Read nsid=1 ok") })
        #expect(output.contains { $0.contains("NVMeController.execute") && $0.contains("finished queue=io") && $0.contains("connection=\(io)") })
        #expect(output.contains { $0.contains("C2HData cid=") } == debug)
    }

    @Test func untracedReadsDoNotCreateConnectionMetadata() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        let command = NVMeCommands.read(commandID: 0, nsid: 1, slba: 0, blocks: 1, blockSize: 4096)
        let completion = try await controller.execute(command, expectedRead: 4096)
        #expect(completion.data == Data(count: 4096))
        #expect(completion.receivedBytes == 4096)
        #expect(completion.connectionID == nil)
        try await controller.logout()
        await fleet.shutdown()
    }
}
