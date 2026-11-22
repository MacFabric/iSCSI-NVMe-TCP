# Backend A performance

All figures from the SIP-off test VM (4 cores, 16 GiB) against the TrueNAS
scratch LUN over the LAN, APFS on the attached disk image.

> **Every number below was measured with Nagle on and TCP keepalive off.**
> `NetworkTransport` set `noDelay` and keepalive on a cast of the IP options
> that never succeeded, so neither took effect until the fix of 2026-10-05.
> Small PDUs — command headers, R2T-driven Data-Out tails, NOP-Outs — could
> wait behind an unacknowledged segment. Re-measure before comparing against
> anything after that date.
>
> First re-measurement (2026-10-05): NVMe/TCP `read-bench` on name-testing
> from a SIP-off 27.0 VM on the storage subnet, the same `iscsictl` built
> before and after the fix, alternated, three runs each. No measurable
> difference: 4 KiB at depth 1 ~14 MB/s both; 4 KiB at depth 8 70–75 both;
> 64 KiB at depth 8 590–730 both (noisy); 1 MiB at depth 4 ~1160 both. The
> first run of each shape was a warm-up outlier.
>
> Writes, the same way with `iscsictl nvme write-bench --fua` (the daemon's
> default), a build with only the old broken cast restored against `main`:
> no measurable difference either — 4 KiB at depth 1 2.0–2.7 MB/s both, 4 KiB
> at depth 8 ~12 both, 64 KiB at depth 8 91–98 both, 1 MiB at depth 4 ~280
> both. FUA writes here are bound by the NAS persisting each one (~2 ms per
> 4 KiB write at depth 1), not by TCP. The fix is correct and, on this LAN,
> neutral.

## Baseline: 137 GB, verified (2026-08-13)

`scripts/bench.py --file-gib 4 --files 8 --rounds 2`, 1 MiB sequential I/O,
SHA-256 verified on read-back, `writeThrough` (FUA) on:

| phase | volume | average |
|---|---|---|
| write | 68.72 GB in 1202 s | **57.2 MB/s** |
| read | 68.72 GB in 764 s | **90.0 MB/s** |
| combined | **137.44 GB** | **69.9 MB/s** |

Zero verify mismatches.

Per-file rates: reads are flat at ~90 MB/s throughout. Writes start at ~65 MB/s
and settle to ~49 MB/s in the second round, i.e. they degrade as the volume
fills and is rewritten — worth remembering when comparing runs, since a short
benchmark on a fresh volume flatters the write number.

## Where the time goes

**The stack is latency-bound, not CPU-bound.** During sustained I/O:

```
iscsid 13.9%   kernel_task 8.3%   iSCSIFSExtension 2.3%   fskitd 1.2%
```

on a 4-core machine — nothing is close to saturated. So throughput is set by
round-trip count and per-command latency, not by processing cost.

At ~57 MB/s with 1 MiB per command that is roughly 15 ms per write, which is
the signature of **FUA forcing a synchronous commit at the target** on every
command. The target confirms a volatile write cache
(`write cache ENABLED` at login), so on ZFS each FUA write is a ZIL commit.

Cost of that durability, same 128 MiB test:

| configuration | write |
|---|---|
| `writeThrough=off` (no FUA) | 117 MB/s |
| `writeThrough=on` (FUA) | 76.9 MB/s |

Disabling FUA is *not* an acceptable optimisation: with no barrier signal from
FSKit (see `backend-a-fskit-notes.md`), FUA is the only thing making an
acknowledged write durable against target power loss.

## Optimisations applied

### CRC32C: 17.4x (done)

The digest covers every byte in both directions. The old implementation was a
byte-at-a-time table loop over a generic `Sequence<UInt8>`, which also defeated
any contiguous fast path. Replaced with the CRC32C instruction (arm64
`__builtin_arm_crc32cd`, x86-64 `_mm_crc32_u64`), 8 bytes per instruction,
slice-by-8 fallback.

Measured over 256 MiB: **8456 MB/s vs 487 MB/s**, identical output.

This did **not** move end-to-end throughput, exactly as the CPU numbers
predicted. It removes a ceiling rather than raising the floor: at 487 MB/s the
digest would have become the limit as soon as concurrency raised the transfer
rate.

## Where the ceiling is

`iscsictl iscsi read-bench` reads straight over iSCSI — no FSKit extension, no
DiskImages, no filesystem — which separates our stack from the transport.
Uncached regions, sequential:

| chunk | raw iSCSI read |
|---|---|
| 256 KiB | 85.3 MB/s |
| 1 MiB (what the stack uses) | 94.5 MB/s |
| 4 MiB | 97.8 MB/s |
| 8 MiB | 98.1 MB/s |

The transport plateaus at **~98 MB/s**. End-to-end reads through FSKit,
DiskImages and APFS measure **90.0 MB/s**, so:

- our layers cost about **4.5%** (94.5 → 90.0 at the same 1 MiB chunk),
- and the stack runs at **~92% of the achievable maximum**.

Read cost by layer, same 512 MiB region:

| path | throughput |
|---|---|
| FSKit + daemon (`lun0.img` directly) | 102 MB/s |
| + DiskImages (`/dev/rdisk`) | 97 MB/s |
| + APFS (mounted volume) | 90 MB/s |

(These vary a few percent run to run because the target's ARC caches recently
written blocks — compare only measurements taken against cold regions.)

## Concurrency: measured, and it does not help

Tested directly rather than assumed, because `ISCSIBlockDevice` is an actor and
serialization looked like an obvious culprit:

| workload | 1 stream | 4 concurrent streams |
|---|---|---|
| write, 2048 MiB total | 49 MB/s | 51 MB/s |
| raw read, 1024 MiB total | 146 MB/s | 113 MB/s |

Writes are flat and reads get **23% worse** — parallel streams break the
sequential access pattern the target reads ahead on. Request size makes no
difference either: writes measured 76–78 MB/s at every block size from 64 KiB
to 16 MiB.

**Conclusion: the actor serialization is not the bottleneck, and pipelining
commands would buy nothing.** Rejected on evidence rather than implemented on
intuition — it would have added real risk (reordering, weakened RMW
serialization) for no measurable gain.

**Half of that is superseded — see the next section.** The measurement above is
sound and the conclusion drawn from it was too broad. Four independent *streams*
is not the same experiment as the chunks of *one* request going out together,
and the two results point opposite ways for a reason worth understanding.

## Splitting one write across concurrent commands: 2.1-2.6x (2026-08-17)

`ISCSIBlockDevice.read` has pipelined the chunks of a single request since the
readahead work. `write` sat three lines below it issuing the same kind of chunks
one at a time, paying a full round trip each. Making it match:

| mode | serial | pipelined | gain |
|---|---|---|---|
| FUA (what ships) | 53.7 / 58.6 / 57.8 -> **56.7** MB/s | 121.6 / 117.0 / 117.2 -> **118.6** | **2.09x** |
| cached | 329.8 / 321.5 / 306.1 -> **319.1** MB/s | 809.3 / 816.2 / 820.8 -> **815.4** | **2.56x** |

512 MiB per pass, 1 MiB requests split into four 256 KiB commands, against
`iscsi-driver-testing`. Interleaved A/B/A/B in one session, per the rule in
`open-questions`: the spread within each arm is 9% and 7%, an order below the
gap, and the worst pipelined run still beats the best serial one 2.00x and
2.45x. The pipelined arm is also the *steadier* of the two (1.4% spread in
cached mode against 7.4%), which is not what noise looks like.

**Why this does not contradict the section above.** Four concurrent streams
write four unrelated LBA regions and destroy the sequential pattern the array
reads ahead on — measured flat for writes and 23% *worse* for reads. Four
concurrent chunks of one request are contiguous by construction: the same
sequential run, in the same order, with the round-trip stall between commands
removed. One scatters the access pattern; the other only stops waiting. The
earlier experiment answered "should separate operations overlap" (no) and was
read as answering "should one operation be split" (which it never tested).

Correctness on hardware, not just throughput: `iscsictl iscsi verify --write --blocks
2048` round-trips 1 MiB — four concurrent commands — byte-exact at LBA 262144.

Note the FUA multiple is roughly preserved, 5.6x before and 6.9x after, so this
does not touch the trade in item 5 of `open-questions`; it makes both sides of
it faster.

## What is actually limiting each direction

- **Reads** are transport-bound at ~98 MB/s.
- **Writes** are target-bound. FUA makes each write a synchronous commit, and
  the target confirms a volatile write cache; on ZFS that is a ZIL commit per
  command, which is why writes neither scale with concurrency nor improve with
  larger requests. The fix is target-side (an SLOG device), not initiator-side.

Remaining initiator-side headroom is roughly 3.5% — the gap between 1 MiB and
4 MiB chunks — and it is not reachable without raising the FSKit volume's
reported `ioSize` and rebuilding the extension. Not worth it for 3.5%.

## Loopback: what the stack costs with no network in the way (2026-08-14)

Every number above was bounded by the LAN. `iscsi-target-sim` running beside the
initiator removes that, so what remains is our own per-command cost — and the
target's negotiation parameters are finally ours to change. RAM-backed LUN,
4 KiB blocks, 1 MiB commands, 1 GiB per run, digests off.

| FirstBurstLength | write | write + FUA | read |
|---|---|---|---|
| 64 KiB (what the NAS allows) | 869 MB/s | 959 MB/s | 2428 MB/s |
| 256 KiB | 958 MB/s | 1054 MB/s | 2440 MB/s |
| 1 MiB | 1055 MB/s | **1196 MB/s** | 2439 MB/s |

**Reads cost us almost nothing.** 2.4 GB/s here against 94.5 MB/s over the LAN:
the transport was ~96% of the read cost, which retires any suspicion that the
read path needed work.

**FirstBurstLength is worth 25% on writes** (959 → 1196 MB/s), and reads are
flat because they never involve R2T. This was Strategy 5, previously untestable
because it is the *target's* setting.

### We were the binding constraint

The first sweep negotiated 256 KiB even when the simulator offered a full
megabyte. `FirstBurstLength` folds by `numericMin`, and our own
`DesiredParameters.firstBurstLength` was 256 KiB — so raising the target's
value past that did nothing. It now asks for `1 << 20`, matching
`maxBurstLength`, which is what unlocks the 1054 → 1196 MB/s step.

The fold makes this safe: a target that cannot buffer a megabyte per command
answers with less and we honour it. **On the real NAS this changes nothing** —
it caps FirstBurstLength at 64 KiB, so the extra R2T round trip per megabyte
stays. The gain is available to targets that allow more.

Verified rather than assumed, because a throughput number alone would not have
caught a `bufferOffset` off-by-one in the unsolicited tail — writes would have
corrupted every megabyte at the same reported rate. Three integration tests
round-trip 2–4 MiB byte-exact at a negotiated 1 MiB first burst (fully
unsolicited, unsolicited-plus-R2T, and with an 8 KiB immediate segment so the
tail carries the most Data-Out PDUs), each asserting the negotiated value first
so it cannot pass while exercising the old 64 KiB shape. The full Backend A
stack was then re-run through the daemon at `FIRSTBURST=1048576`: baseline,
drop and crash all pass, `fsck_apfs` clean.

### One number here is a simulator artifact

FUA measures *faster* than non-FUA (1196 vs 1055 MB/s), which is backwards. It
is an artifact of the simulator's cache: a non-FUA write is stored as
per-block dictionary entries (256 inserts per MiB) while a FUA write is a
single copy straight to the backing store, so "caching" costs more than
"committing". Nothing about FUA being cheap should be read from this table —
the honest measurement of FUA's cost is the LAN one above (~1.5× on large
sequential, ~2.5× on small writes), where a real target really does commit.

## Hot-loop audit (2026-08-14)

Looked for byte-at-a-time work and avoidable copies on the data path.

**Already clean:** the PDU codec and framer operate on `Data` slices via the
slice-tolerant helpers in `Support/Endian.swift`, not by iterating bytes; the
receive loop feeds the deframer whole chunks from the transport;
`ISCSIBlockDevice.read` preallocates its output. The only per-byte loops in the
library are in IQN validation and trace formatting, neither of which is on the
data path.

**Two real costs found and removed, both per-PDU:**

1. `PDUSerializer.serialize` built `raw.data + padding` solely to compute a
   four-byte data digest — allocating and copying the whole data segment, up to
   a megabyte per PDU. Now chains the digest over the segment and its padding
   with `CRC32C.update`/`finalize`, with no copy.

2. `PDUDeframer.next` consumed each PDU with `buffer.removeFirst(total)`, which
   memmoves everything still buffered. That is quadratic when one read delivers
   many PDUs — the normal case on a fast link. Now advances a `consumed` index
   (O(1)) and reclaims the dead prefix in one memmove once it passes 64 KiB or
   half the buffer.

Both are correctness-neutral. The index change touches every offset in `next()`
including the digest verification, where an off-by-one would corrupt every PDU
after the first, so four tests cover multi-PDU appends, repeated compactions,
split PDUs with partial tails, and digest checks on later PDUs.

**Not worth vectorising.** CRC32C is the only genuine bulk-byte computation in
the stack and already uses the hardware instruction (8.4 GB/s). Everything else
that touches large buffers is a copy, where `memcpy` is already optimal, or a
network round trip, where the CPU is idle — `iscsid` sits at ~14% of four cores
under sustained load. There is no remaining loop where SIMD would pay.


## Post-optimisation re-benchmark (2026-08-14)

Same 137 GB run after the CRC32C, framer, and block-alignment work:

| phase | before | after |
|---|---|---|
| write | 57.2 MB/s | 56.6 MB/s |
| read | 90.0 MB/s | 90.6 MB/s |
| combined | 69.9 MB/s | 69.6 MB/s |

**No change, and that is the expected result.** This benchmark is 1 MiB
aligned, so it has no read-modify-write to eliminate; digests are negotiated
off, so CRC32C never runs; and the stack is latency-bound at ~14% CPU, so
cheaper framing frees capacity that was not the constraint. The optimisations
are real but invisible to this workload — which is the argument for keeping a
small-write soak alongside a sequential benchmark.

### Cost of FUA on small writes

The soak (4 workers, unaligned partial overwrites, 3 GB memory pressure) shows
the durability cost far more sharply than the sequential benchmark does:

| configuration | soak write | soak read |
|---|---|---|
| `writeThrough=on` (FUA) | 12–14 MB/s | 25–28 MB/s |
| `writeThrough=off` | ~31 MB/s | ~62 MB/s |

Roughly **2.5x**, against ~1.5x for large sequential writes. That follows from
the earlier finding that the cost scales with synced bytes rather than commands:
small writes pay a full commit for very little data.

This is the price of durability on a target with a volatile write cache, and it
is why the shipping default stays `writeThrough=on`.

### A false alarm worth recording

One soak run reported 13,267 verification mismatches, which looked like data
corruption. It was not: a previously backgrounded command had failed its mount
step but still launched a second `soak.py` against the same directory, and both
instances write the same fixed file names (`soak-0.bin` … `soak-3.bin`). Each
was reading back the other's data.

Confirmed by elimination: single-threaded clean (0/200), 4 threads clean
(0/600), soak without memory pressure clean (26,231 verifies), and the identical
failing configuration re-run with one instance clean (51,116 verifies). No
double mount was involved — the logs show exactly one `mount-complete` for the
volume.

Lesson for the harness: `soak.py` should use per-process unique file names so a
stray instance collides visibly rather than looking like corruption.

## Data-path audit (2026-11-22)

A read-through of FabricKit, iSCSIKit, NVMeKit, `InitiatorShared` and
`iSCSIVolume` for algorithms, parallelism and vector work. What was changed,
and where.

### In this repository

- **A write patches the cached chunk in place.** `PrefetchChunkCache.didWrite`
  copied the whole 256 KiB entry for every write that touched it, under the
  cache's lock, because the entry still held the bytes it was copying from. A
  4 KiB write now costs 4 KiB. Small against a 2 ms FUA write; free to fix.
- **The disk tier's GCM tag stays in memory.** It had a 4 KiB page of its own
  after each chunk: a second `pread` and `pwrite` per chunk, and 4 KiB of disk
  per slot. The slot table is in memory and dies with the session, exactly as
  the tag on disk did.
- **A read-modify-write reads from the cache when it can.** The read half
  always went to the daemon. `PrefetchChunkCache.peek` answers it when every
  byte is in memory, without waiting on a fetch in flight and without counting
  as a read of the workload's. Safe under `ioLock`, where each acknowledged
  write is already patched in.

### In the kits (FabricKit, iSCSIKit and NVMeKit 0.1.1)

- **The engines keep receiving while they answer an R2T.** Both read loops
  sent the Data-Out (H2CData) themselves and waited for the transport to take
  each PDU. Against a full send buffer that is as long as the network takes to
  drain it, and nothing was received meanwhile: no Data-In, no status, no
  window update for any other command. With the NAS's 64 KiB FirstBurstLength
  every 256 KiB write goes through an R2T. The answer is now queued whole and
  not waited for. Covered by a test per engine that holds the Data-Out in the
  transport and requires a read that arrived behind the R2T to complete.
- **Write data is not copied on its way to the socket.** Three to four copies
  per byte on iSCSI, two to three on NVMe/TCP, are gone: the payload is a
  slice of the caller's buffer down to `ConnectionTransport.send(contentsOf:)`,
  which sends header and payload from separate buffers.
- **One send per sequence**, not one per PDU: a command with its unsolicited
  Data-Out, and each R2T's answer.
- `NetworkTransport.receive` returns up to 1 MiB, from 256 KiB, and
  `NVMeTCPDeframer` no longer allocates `lastHeader` for every PDU.

Loopback, `iscsi-target-sim` built on the 0.1.0 kits as the target for both arms, `iscsictl`
before and after, alternated, three runs each of 1 GiB in 1 MiB requests
split into four 256 KiB commands (M1 Max, FirstBurstLength 64 KiB):

| | before | after | |
|---|---|---|---|
| iSCSI write | 308 / 330 / 320 | 383 / 365 / 394 | **+19%** |
| iSCSI write, FUA | 413 / 373 / 372 | 474 / 475 / 422 | **+18%** |
| NVMe/TCP write | 245 / 268 / 245 | 279 / 275 / 284 | **+10%** |
| NVMe/TCP write, FUA | 311 / 309 / 265 | 335 / 335 / 325 | **+12%** |
| iSCSI read | 682 / 665 / 587 | 623 / 669 / 653 | none |
| NVMe/TCP read | 417 / 488 / 449 | 483 / 408 / 478 | none |

MB/s. The write arms do not overlap except iSCSI FUA, by one run. Reads were
not expected to move and did not: the receive cap is not what bounds them
here. These runs measure the copies and the per-PDU sends. They do not
measure the R2T change, which needs reads and writes on one connection and
which no bench here produces; that one rests on its tests until a mixed run
against a real target says more. On the 1 GbE NAS none of this should show,
for the reason this document opens with.

### On the NAS, through the whole stack: no change, as predicted

VM 26 (26.7.3), `name-testing` over NVMe/TCP, attached with `hdiutil`. A
verified mixed load: three 512 MiB files per phase in 1 MiB calls, `F_NOCACHE`
on reads and writes, every read checked against a SHA-256 of what was written.
Build 57.1 is main before this work; 57.3 is this branch on the 0.1.1 kits.
Two runs each, MiB/s:

| phase | 57.1 | 57.3 |
|---|---|---|
| write alone, 3 streams | 36.7 / 37.2 | 37.1 / 36.8 |
| read alone, 3 streams | 102.9 / 104.4 | 108.7 / 93.9 |
| read 3 files while writing 3 | 60.3 / 63.6 | 63.3 / 59.7 |
| read 6 files | 101.8 / 109.0 | 104.8 / 103.7 |

Nothing moved outside run-to-run spread, and every read verified. Two earlier
57.3 runs, taken while the NAS was busy with other work, read 10 to 25% slower
and looked like a regression until these were taken back to back.

**A write stall this load exposes, in both builds.** One `write()` of 1 MiB
takes 10 to 19 s in most runs (57.1: 10.7, 17.5 and 16.3 s; 57.3: 16.2, 19.4,
16.3, 17.5 and 10.6 s), always on one of three concurrent writers, while the
extension logs no write or flush of a second or more and its longest write is
about half a second. The time is spent above the extension, on the default
`hdiutil` attach. Not explained.

### The rest of the list (2026-11-22, later)

Everything the first pass left alone, bar one item. The kits' part is
FabricKit, iSCSIKit and NVMeKit 0.1.2.

- **CRC32C runs three instruction chains at once**, folded with PMULL. The
  instruction has a three-cycle latency, so one chain used a third of the
  core. 4 KiB 7.5 → 19.6 GB/s, 64 KiB 7.1 → 21.3, 1 MiB 6.5 → 16.0; a
  48-byte header is unchanged. It matters more than this document used to
  say: digests are off for iSCSI on the NAS, but the daemon asks for them on
  every NVMe/TCP controller and TrueNAS grants them.
- **A byte read is copied once, not four times.** The deframers keep
  received chunks as they came and hand a PDU over in steps: the header
  first, then the data moved from those chunks straight into the buffer of
  the read it answers. That buffer is one allocation for the whole read,
  shared by the commands it is split into, not zeroed first, and returned as
  `Data` without a copy.
- **`NWConnection.send` copies a `Data` it is given**, whole, before it
  returns: 256 MiB sent to a peer that was not reading grew the process by
  256 MiB at once. Parts of 16 KiB and more now go as dispatch data that
  refers to the caller's bytes, which grew it by nothing.
- **Deadlines share one sleeping task.** `withDeadline` made a task per
  command to sleep through the timeout. 5.2 → 2.7 µs per call; what is left
  is the task the operation runs in, which is what lets a deadline hold over
  work that ignores cancellation.
- **Big- and little-endian fields are read in one load**, 12 → 6 ns for a
  32-bit field, still trapping on an offset outside the buffer.
- **A disk-tier lookup over several chunks reads and decrypts them at once.**
- **NVMe/TCP can open several I/O queues** (`NVMeControllerConfig.
  ioQueueCount`, `iscsictl nvme … --io-queues`, `NVME_IO_QUEUES` for the
  daemon). One is still the default.

**What a read costs the initiator.** Loopback, `iscsictl` on the 0.1.1 kits
against this work, alternated, three runs each of 1 GiB; CPU seconds (user
plus system) of the `iscsictl` process, which is far steadier here than
throughput:

| | 0.1.1 | now | |
|---|---|---|---|
| iSCSI read | 0.90 / 1.05 / 0.98 | 0.58 / 0.63 / 0.79 | **−36%** |
| iSCSI read, digests | 1.03 / 1.16 / 1.17 | 0.60 / 0.63 / 0.71 | **−46%** |
| NVMe/TCP read, digests | 1.40 / 1.29 / 1.39 | 0.84 / 0.91 / 0.83 | **−40%** |
| NVMe/TCP read | 1.24 / 1.41 / 1.44 | 0.80 / 0.91 / 0.85 | **−40%** |
| iSCSI write (six runs, mean) | 1.01 | 0.95 | −6% |
| NVMe/TCP write (six runs, mean) | 1.24 | 1.21 | −2% |

Peak memory of the reading process fell from 22–25 MiB to 15–17. Writes are
two thirds system time, the kernel's own copy into the socket, which nothing
here touches. Throughput on the same runs moved the same way for reads
(iSCSI with digests: median 602 → 814 MB/s over five runs) but the ranges
overlap for most shapes: this machine was running two VMs, and the simulator
is the slower end of the pipe.

**Several I/O queues, loopback.** Median of four runs, MB/s:

| | 1 queue | 2 | 4 |
|---|---|---|---|
| read, 1 MiB, depth 4 | 816 | 980 | 1045 |
| read, 64 KiB, depth 8 | 565 | 533 | 558 |
| read, 4 KiB, depth 32 | 71 | 80 | 81 |
| write, 1 MiB, depth 4 | 468 | 608 | 611 |
| write, 4 KiB, depth 32 | 78 | 89 | 80 |

A fifth to a third more on megabyte transfers, a tenth on 4 KiB, nothing at
64 KiB, and little past two. The simulator's disk is one actor, so this
understates a target that serves queues independently and says nothing about
one whose readahead dislikes a sequential read arriving on several
connections.

**Several I/O queues, on the NAS: no gain, so the default stays at one.**
VM 26 (two cores), `iscsictl nvme read-bench` from build 57.4's bundle
against `name-testing`, CRC32C digests on, four alternated runs; median MB/s
and CPU seconds of the tool:

| | 1 queue | 2 | 4 |
|---|---|---|---|
| 1 MiB, depth 1 | 219, 1.28 s | 224, 1.54 s | 218, 1.64 s |
| 1 MiB, depth 4 | 299, 1.20 s | 325, 1.41 s | 271, 1.69 s |
| 64 KiB, depth 8 | 229, 1.03 s | 221, 1.14 s | 206, 1.28 s |
| 4 KiB, depth 32 | 71, 0.92 s | 66, 0.92 s | 61, 0.98 s |

Two queues are inside the noise of one and cost more CPU; four are a little
slower at every size. This rig is bound by the VM's network path at about
300 MB/s and has two cores, so there is nothing for a second receive loop to
unlock. A host with a faster link and more cores is where to ask again.

**The same reads, 0.1.1 engine against 0.1.2, on the NAS.** Three alternated
runs, one queue; throughput did not move (1 MiB at depth 1: 169 / 217 / 205
against 216 / 221 / 198 MB/s), which is the link. CPU seconds for the same
work did:

| | 0.1.1 | 0.1.2 |
|---|---|---|
| 1 GiB in 1 MiB requests, depth 1 | 2.04 / 1.78 / 2.26 | 1.13 / 1.36 / 1.63 |
| 1 GiB in 1 MiB requests, depth 4 | 1.89 / 1.62 / 2.15 | 1.10 / 1.47 / 1.57 |
| 512 MiB in 64 KiB requests, depth 8 | 1.45 / 1.43 / 2.01 | 0.89 / 1.25 / 1.19 |
| 64 MiB in 4 KiB requests, depth 8 | 1.49 / 1.56 / 2.00 | 1.14 / 1.35 / 1.06 |

About a third less at a megabyte, a fifth to a quarter below. The 0.1.1
binary is a SwiftPM build and the 0.1.2 one is Xcode's from the bundle, which
is a difference this table cannot separate from the engines'.

**Through the whole stack, build 57.4.** The mixed load of the section above
(`scripts/mixed-load.py /Volumes/name-testing 512 3`), a throwaway run and
then two, MiB/s:

| phase | 57.1 and 57.3, earlier the same day | 57.4 |
|---|---|---|
| write alone | 36.7 / 37.2 / 37.1 / 36.8 | 50.2 / 41.1 (throwaway 43.4) |
| read alone | 102.9 / 104.4 / 108.7 / 93.9 | 107.0 / 105.1 |
| read 3 files while writing 3 | 60.3 / 63.6 / 63.3 / 59.7 | 69.0 / 68.5 |
| read 6 files | 101.8 / 109.0 / 104.8 / 103.7 | 101.6 / 96.9 |

Every read verified, no slow-I/O or recovery lines. Reads are where they
were. Writes are 11 to 35% up and the mixed phase 8 to 15%, with every 57.4
run above every earlier one; that would fit NVMe/TCP writes carrying a data
digest that is now three times cheaper to compute, on a two-core VM. But the
two columns were taken two hours apart with the NAS busy in between, and
that kind of gap has misled this document once today already. Not claimed
until the builds are run back to back. The write stall of item 21 in
`open-questions.md` is still there: 11.5, 8.0, 16.4 and 16.7 s.

**Checked on the NAS, lightly.** From VM 26, read-only: four 8 MiB ranges of
`name-testing` holding real data (58 to 96% non-zero) read with the 0.1.1
engine and with this one, on one, two, three and four queues (TrueNAS
granted four), with CRC32C digests and without, in 64 KiB, 256 KiB and 1 MiB
commands, up to eight requests at once. Every SHA-256 matched. Both fuzz
harnesses now take each input through the stepwise deframers as well and
require them to agree with `next()`: 1.6 and 1.2 million inputs under ASan,
no crashes.

### The same suite with four cores, on both VMs (2026-11-22, afternoon)

Both test VMs were raised from two cores to four and run one at a time:
VM 26 (26.7.3) and VM 27 (27.2.1), build 57.4, `name-testing` write-through
on both. VM 27 had it saved with a 5 s periodic flush until this run, which
is why its earlier numbers are not in this table.

Mixed load, after a throwaway run, MiB/s:

| phase | VM 26, 2 cores | VM 26, 4 cores | VM 27, 4 cores |
|---|---|---|---|
| write alone | 50.2 / 41.1 | 39.7 / 34.2 | 43.0 / 46.1 |
| read alone | 107.0 / 105.1 | 98.4 / 89.4 | 80.2 / 132.6 |
| read 3 files while writing 3 | 69.0 / 68.5 | 57.9 / 63.1 | 55.3 / 72.8 |
| read 6 files | 101.6 / 96.9 | 100.8 / 98.9 | 137.9 / 144.1 |

Every read verified. Two more cores bought nothing on VM 26, and its
write-alone figure moved from 34 to 50 across four runs of one build an hour
apart. So the "57.4 writes faster than 57.1" reading above is withdrawn:
that spread is the NAS, and it is wider than the difference it was read
from.

Raw reads, 0.1.1 engine against 0.1.2, one queue, median of three alternated
runs, MB/s with the tool's CPU seconds:

| | VM 26: 0.1.1 | 0.1.2 | VM 27: 0.1.1 | 0.1.2 |
|---|---|---|---|---|
| 1 MiB, depth 1 | 154, 2.47 s | 161, 2.17 s | 320, 2.29 s | 340, 1.73 s |
| 1 MiB, depth 4 | 222, 2.99 s | 229, 1.97 s | 505, 2.10 s | 484, 1.70 s |
| 64 KiB, depth 8 | 155, 2.41 s | 185, 1.52 s | 383, 1.82 s | 402, 1.33 s |
| 4 KiB, depth 32 | 39, 1.85 s | 47, 1.16 s | 94, 1.54 s | 125, 1.17 s |

(VM 27's 64 KiB row is eight alternated runs: the first three had the new
engine 10% behind, and the longer run did not.) Throughput at a megabyte is
the link, on both. **Small reads are where the new engine is faster on a
real target**: 4 KiB at depth 32 is 20% up on VM 26 and 33% up on VM 27,
with the ranges apart on VM 27 (87 to 101 against 122 to 131). CPU for the
same work is 12 to 37% lower everywhere. The same eight runs included a
SwiftPM build of the 0.1.2 engine beside Xcode's from the bundle: 393 MB/s
and 1.37 s against 402 and 1.33, so the build system is not what the tables
above are measuring.

I/O queues with four cores, median of four alternated runs, MB/s:

| | VM 26: 1 queue | 2 | 4 | VM 27: 1 queue | 2 | 4 |
|---|---|---|---|---|---|---|
| 1 MiB, depth 1 | 173 | 158 | 171 | 333 | 327 | 338 |
| 1 MiB, depth 4 | 226 | 221 | 232 | 490 | 480 | 472 |
| 64 KiB, depth 8 | 173 | 165 | 175 | 321 | 351 | 318 |
| 4 KiB, depth 32 | 61 | 52 | 55 | 128 | 102 | 124 |

Still nothing, with the cores to use them and on the faster of the two
links, and each extra queue costs CPU (VM 27, 1 MiB at depth 4: 1.75, 2.19
and 2.55 s). One queue stays the default, and against this NAS there is no
case for the knob.

Two things about method that cost time here. A benchmark started with
`nohup` over ssh loses the local network when the session closes: every
connect from it then times out, which looked like a dead target. File-level
load survives being detached; anything that opens a socket has to run in a
live session. And a mixed-load run on VM 27, while it still had the 5 s
flush, slowed to 1 to 2 s per megabyte written for six minutes, with the
daemon idle and a second connection from the old engine reading at 31 MB/s;
both recovered when the load was stopped. Not explained, and not seen again
once the target was write-through.

### Left alone

- **Waking every CmdSN-window waiter on each window update.** Waking only as
  many as the window opened is not a safe trade at these depths: a woken
  waiter that turns out to be cancelled would strand the ones behind it.
- **The task `withDeadline` runs the operation in**, and the task per send
  that keeps iSCSI's PDUs in CmdSN order. Both are what make a stuck
  operation survivable.
