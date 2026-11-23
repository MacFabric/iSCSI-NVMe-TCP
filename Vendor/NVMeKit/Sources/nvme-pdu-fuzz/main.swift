import Foundation
import NVMeKit

/// Fuzz body: everything reachable from untrusted wire bytes must not crash.
/// Kept libFuzzer-compatible (LLVMFuzzerTestOneInput) even though Apple's
/// Xcode toolchain ships no libFuzzer runtime — scripts/fuzz.sh drives the
/// built-in mutation engine below under ASan instead.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzBody(Data(bytes: start, count: count))
    return 0
}

func fuzzBody(_ data: Data) {
    nvmeStateless(data)
    // Again at a non-zero startIndex: fresh Data always starts at 0, which
    // cannot catch indexing a *slice* with an absolute offset. This pins the
    // `self[startIndex + offset]` accessors in FabricKit's Endian and
    // NVMeKit's little-endian twins.
    var prefixed = Data([0xAA, 0x55, 0x00])
    prefixed.append(data)
    nvmeStateless(prefixed.dropFirst(3))
}

/// NVMe/TCP: the deframer under both digest configurations, every PDU
/// decoder with re-encode, and the bare parsers of controller-supplied
/// structures (Identify, the active namespace list, the discovery log, the
/// CQE/SQE layouts). A missed bounds check here is a trap, not a wrong
/// answer.
private func nvmeStateless(_ data: Data) {
    for digests in [NVMeTCPDigests(), NVMeTCPDigests(header: true, data: true)] {
        var deframer = NVMeTCPDeframer(digests: digests, maxPDUBytes: 1 << 20)
        deframer.append(data)
        while let raw = try? deframer.next() {
            if let pdu = try? AnyNVMeTCPPDU.decode(raw) {
                _ = pdu.encode()
            }
        }
    }
    _ = try? IdentifyController(data: data)
    // The parse alone never reached the trap this harness missed: MDTS turned
    // into bytes, which overflowed from MDTS 51 and killed the daemon. Padded
    // to full size so short inputs get there, with the first byte as MDTS,
    // against every page size CAP.MPSMIN can name and the one CAP here names.
    var identify = Data(count: IdentifyController.size)
    identify.replaceSubrange(0 ..< min(data.count, identify.count), with: data.prefix(identify.count))
    if let mdts = data.first { identify[77] = mdts }
    if let id = try? IdentifyController(data: identify) {
        for mpsmin in 0 ... 15 { _ = id.maxTransferBytes(pageBytes: 1 << (12 + mpsmin)) }
        let cap = data.prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        _ = id.maxTransferBytes(pageBytes: ControllerCapabilities(raw: cap).minPageBytes)
    }
    _ = try? IdentifyNamespace.geometry(from: data)
    _ = ActiveNamespaceList.parse(data)
    _ = try? DiscoveryLogPage.parse(data)
    _ = try? CQE(bytes: data.prefix(16))
    _ = try? SQE(bytes: data.prefix(64))
    if data.count >= 16 {
        let cqe = try? CQE(bytes: data.prefix(16))
        _ = cqe?.status.description
    }
}

#if !FUZZING

// MARK: - Deterministic mutation engine

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Valid NVMe/TCP PDUs and controller structures as mutation bases.
func seedCorpus() -> [Data] {
    var seeds: [Data] = []
    let plain = NVMeTCPSerializer()
    let digested = NVMeTCPSerializer(digests: NVMeTCPDigests(header: true, data: true))

    var icreq = ICReqPDU()
    icreq.digests = NVMeTCPDigests(header: true, data: true)
    seeds.append(plain.serialize(icreq.encode()))
    seeds.append(plain.serialize(ICRespPDU(digests: NVMeTCPDigests(header: true), maxH2CData: 65536).encode()))

    let read = NVMeCommands.read(commandID: 3, nsid: 1, slba: 64, blocks: 8, blockSize: 512)
    seeds.append(plain.serialize(CapsuleCmdPDU(sqe: read.bytes).encode()))
    let write = NVMeCommands.write(commandID: 4, nsid: 1, slba: 0, blocks: 1, blockSize: 512,
                                   fua: true, inCapsule: true)
    seeds.append(digested.serialize(CapsuleCmdPDU(sqe: write.bytes,
                                                  inCapsuleData: Data(repeating: 0x5A, count: 512)).encode()))
    seeds.append(plain.serialize(CapsuleRespPDU(cqe: CQE(dw0: 7, commandID: 3).encoded).encode()))
    seeds.append(digested.serialize(C2HDataPDU(cccid: 3, dataOffset: 0,
                                               data: Data(repeating: 0xA5, count: 1024),
                                               last: true, success: false).encode()))
    seeds.append(plain.serialize(NVMeR2TPDU(cccid: 4, ttag: 1, offset: 0, length: 65536).encode()))
    seeds.append(plain.serialize(C2HTermReqPDU(fes: .headerDigestError, fei: 0,
                                               offendingHeader: Data([7, 0, 24, 24, 24, 0, 0, 0])).encode()))

    // A C2HData with controller-side alignment padding: PDO past HLEN, which
    // is the one layout the serializer never produces and the deframer must
    // still get right.
    var padded = Data([0x07, 0x04, 24, 32, 0, 0, 0, 0])
    padded.setLE32(32 + 512, 4)
    var psh = Data(count: 16)
    psh.setLE16(5, 0)
    psh.setLE32(512, 8)
    padded.append(psh)
    padded.append(Data(repeating: 0xFF, count: 8))
    padded.append(Data(repeating: 0x33, count: 512))
    seeds.append(padded)

    // Bare controller structures, for the parsers that take a data buffer.
    var ns = Data(count: 4096)
    ns.setLE64(262_144, 0)
    ns.setU8(1, 25)
    ns.setU8(1, 26)
    ns.setU8(9, 130)
    ns.setU8(12, 134)
    seeds.append(ns)

    var ctrl = Data(count: 4096)
    ctrl.setSub(Data("SIM0000000000000001 ".utf8), 4)
    ctrl.setU8(5, 77)
    ctrl.setLE16(1, 78)
    ctrl.setU8(1, 525)
    ctrl.setSub(Data("nqn.2026-08.me.herko.sim:disk0".utf8), 768)
    ctrl.setLE32(1028, 1792)
    seeds.append(ctrl)

    var disc = Data(count: 1024)
    disc.setLE64(1, 0)
    disc.setLE64(1, 8)
    var entry = Data(count: 1024)
    entry.setU8(3, 0)
    entry.setU8(1, 1)
    entry.setU8(2, 2)
    entry.setLE16(0xFFFF, 6)
    entry.setSub(Data("4420".utf8), 32)
    entry.setSub(Data("nqn.2026-08.me.herko.sim:disk0".utf8), 256)
    entry.setSub(Data("127.0.0.1".utf8), 512)
    disc.append(entry)
    seeds.append(disc)

    return seeds
}

/// Derive the fuzz input for (seed, iteration) — fully deterministic so any
/// crash reproduces from the two numbers ASan prints alongside our progress.
func deriveInput(seeds: [Data], seed: UInt64, iteration: UInt64) -> Data {
    var rng = SplitMix64(state: seed &* 0x9E37_79B9 &+ iteration)
    var input = seeds[Int(rng.next() % UInt64(seeds.count))]

    // Occasionally concatenate a second PDU (stream handling).
    if rng.next() % 4 == 0 {
        input += seeds[Int(rng.next() % UInt64(seeds.count))]
    }

    let mutations = 1 + Int(rng.next() % 8)
    for _ in 0 ..< mutations {
        switch rng.next() % 11 {
        case 10: // attack the NVMe/TCP HLEN / PDO bytes
            let off = 2 + Int(rng.next() % 2)
            if input.count > off {
                var d = Data(input)
                d.setU8(UInt8(rng.next() % 256), off)
                input = d
            }
        case 0 where input.count > 1: // truncate
            input = input.prefix(Int(rng.next() % UInt64(input.count)) + 1)
        case 1: // extend with junk
            input += Data((0 ..< (rng.next() % 64)).map { _ in UInt8(rng.next() % 256) })
        case 2: // attack the length field (PLEN)
            let off = 4 + Int(rng.next() % 4)
            if input.count > off {
                var d = Data(input)
                d.setU8(UInt8(rng.next() % 256), off)
                input = d
            }
        case 3: // swap the PDU type byte
            if !input.isEmpty {
                var d = Data(input)
                d.setU8(UInt8(rng.next() % 256), 0)
                input = d
            }
        default: // random byte flip
            if !input.isEmpty {
                var d = Data(input)
                let off = Int(rng.next() % UInt64(d.count))
                d.setU8(d.u8(off) ^ UInt8(1 << (rng.next() % 8)), off)
                input = d
            }
        }
    }
    return input
}

// MARK: - CLI

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "help" {
case "fuzz":
    let seconds = args.count > 2 ? Double(args[2]) ?? 30 : 30
    let seed = args.count > 3 ? UInt64(args[3]) ?? 1 : 1
    let seeds = seedCorpus()
    // Self-check: all seeds must survive the body un-mutated.
    for s in seeds { fuzzBody(s) }
    let deadline = Date().addingTimeInterval(seconds)
    var iteration: UInt64 = 0
    print("fuzzing: seed=\(seed) (reproduce any crash with: nvme-pdu-fuzz derive \(seed) <iteration>)")
    while Date() < deadline {
        for _ in 0 ..< 10000 {
            fuzzBody(deriveInput(seeds: seeds, seed: seed, iteration: iteration))
            iteration += 1
        }
        print("iteration \(iteration)")
    }
    print("done: \(iteration) inputs, no crashes")

case "derive":
    // Re-create one input and run it: nvme-pdu-fuzz derive <seed> <iteration> [out-file]
    guard args.count >= 4, let seed = UInt64(args[2]), let iter = UInt64(args[3]) else {
        FileHandle.standardError.write(Data("usage: nvme-pdu-fuzz derive <seed> <iteration> [out]\n".utf8))
        exit(2)
    }
    let input = deriveInput(seeds: seedCorpus(), seed: seed, iteration: iter)
    if args.count > 4 {
        try input.write(to: URL(fileURLWithPath: args[4]))
        print("wrote \(input.count) bytes to \(args[4])")
    }
    fuzzBody(input)
    print("ok (\(input.count) bytes)")

case "replay":
    for path in args.dropFirst(2) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            continue
        }
        fuzzBody(data)
        print("ok \(path) (\(data.count) bytes)")
    }

default:
    print("""
    usage:
      nvme-pdu-fuzz fuzz [seconds] [seed]        run the mutation fuzzer
      nvme-pdu-fuzz derive <seed> <iteration>    reproduce one input
      nvme-pdu-fuzz replay <files...>            run saved inputs
    """)
}
#endif
