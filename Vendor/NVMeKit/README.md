# NVMeKit

An NVMe/TCP host engine in Swift (NVMe over Fabrics, TCP transport). It opens
no sockets of its own and has no side effects, so every path is unit-testable
and fuzzable; the transport comes from
[FabricKit](https://github.com/MacFabric/FabricKit), which NVMeKit re-exports.
It is the twin of [iSCSIKit](https://github.com/MacFabric/iSCSIKit), and
neither knows the other exists.

- **PDU layer.** The nine NVMe/TCP PDU types, a serializer and an incremental
  deframer. Data is located by PDO, HDGST covers the common and PDU-specific
  headers, DDGST covers the data only, and PLEN is bounded before a byte of
  payload is buffered.
- **Capsules.** SQE builders for every command sent (Fabrics Connect, Property
  Get and Set, Identify, Set Features, Get Log Page, Keep Alive, Read, Write,
  Flush) with the SGL encodings NVMe/TCP uses; CQE and status decoding; the
  Identify Controller and Namespace, active namespace list and discovery log
  parsers.
- **Session.** `NVMeQueue` is one connection, which is one queue pair.
  `NVMeController` brings up the admin and I/O queues, keeps the controller
  alive, and recovers from a dropped connection with bounded transparent
  retry. `NVMeDiscovery.getLogPage` reads a discovery controller's log.
- **`NVMeBlockDevice`**, a FabricKit `BlockDeviceBackend` over one namespace,
  with optional Force Unit Access on every write.
- **`NVMeHostIdentity`** derives the host NQN and host ID from a UUID.
  Subsystems' allowed-hosts lists key on that NQN, so **its derivation must
  never change**: a different NQN for the same machine locks that machine out
  of every subsystem that admitted it.

Verified against Linux `nvmet` (TrueNAS SCALE 25.10). No in-band
authentication (DH-HMAC-CHAP) and no TLS: a subsystem that requires either is
refused with a status that says so.

## Products

- `NVMeKit`
- `NVMeMockTarget`, a scriptable in-process NVMe/TCP subsystem
  (`MockNVMeSubsystem`) over `MemoryPipe` or TCP with switchable faults. The
  integration suite runs against it, and so can yours.

## Use

```swift
.package(url: "https://github.com/MacFabric/NVMeKit", .upToNextMinor(from: "0.1.0")),
```

```swift
import NVMeKit

let host = NVMeHostIdentity(uuid: UUID())  // use a stable UUID: see above
let config = NVMeControllerConfig(host: host, subsystemNQN: "nqn.2011-06.com.truenas:uuid:…")
let controller = NVMeController(config: config) {
    try await NetworkTransport.connect(host: "192.168.1.50", port: 4420)
}
try await controller.activate()
let disk = NVMeBlockDevice(controller: controller, nsid: 1)
let firstBlock = try await disk.read(offset: 0, length: try await disk.readCapacity().blockSize)
try await controller.logout()
```

Before 1.0 a minor release may change the API, so depend up to the next minor
version.

## Requirements

macOS 15 or later, Swift 6 (language mode 6).

## Testing

```sh
swift test --no-parallel        # unit and integration suites
scripts/fuzz.sh 60              # 60 s ASan fuzz of the decoders and parsers
scripts/fuzz-campaign.sh 100 20 # 100 independent seeds, 20 s each
```

Serial on purpose: several tests bound real durations, and a saturated machine
makes every continuation late without making any timeout wrong. A fuzz failure
reproduces exactly from the two numbers it prints, with
`nvme-pdu-fuzz derive <seed> <iteration>`.

## Provenance

Developed as part of [iSCSI-NVMe-TCP](https://github.com/MacFabric/iSCSI-NVMe-TCP),
a user-space iSCSI and NVMe/TCP initiator for macOS, and split out of it with
its history on 2026-11-15. Comments that cite `docs/…` refer to that
repository, as does the record of what was tested against which targets.

## License

Apache 2.0. See [LICENSE](LICENSE).
