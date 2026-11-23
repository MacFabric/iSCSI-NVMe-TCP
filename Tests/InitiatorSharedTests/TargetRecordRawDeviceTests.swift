import Foundation
import Testing
@testable import InitiatorShared

@Suite("Target record raw-device key")
struct TargetRecordRawDeviceTests {

    @Test("a record without the key mounts its volumes")
    func olderRecordMounts() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0","localCacheGB":4}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.attachAsRawDevice == nil)
        #expect(record.mountsVolumes)
    }

    @Test("only true attaches raw")
    func onlyTrueIsRaw() {
        for (value, mounts) in [(Bool?.none, true), (false, true), (true, false)] {
            let record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                      targetIQN: "iqn.x", attachAsRawDevice: value)
            #expect(record.mountsVolumes == mounts)
        }
    }

    @Test("the key round-trips, and is absent when unset")
    func roundTrips() throws {
        let raw = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                               targetIQN: "iqn.x", attachAsRawDevice: true)
        let decoded = try JSONDecoder().decode(TargetRecord.self,
                                               from: JSONEncoder().encode(raw))
        #expect(decoded == raw)
        let plain = TargetRecord(id: "t1", displayName: "NAS", host: "nas", targetIQN: "iqn.x")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("attachAsRawDevice"))
    }
}
