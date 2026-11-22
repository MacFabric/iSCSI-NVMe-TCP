#!/usr/bin/python3
"""Reproduce and catch the long write() seen with scripts/mixed-load.py.

    write-stall.py <dir> <MiB per file> <writers> [--fsync-every N] [--no-nocache] [--capture CMD]

Each writer writes its own file in 1 MiB calls, with F_FULLFSYNC every N MiB
(0: never; default 64). Every call of 0.5 s or more is recorded with what the
other writers were doing meanwhile, and the first time a call has been
outstanding for 3 s, CMD is run once (a spindump, say) while it still is.
Removes its own files."""
import fcntl, os, subprocess, sys, threading, time
args = sys.argv[1:]
root, mib, writers = args[0], int(args[1]), int(args[2])
fsync_every = int(args[args.index("--fsync-every") + 1]) if "--fsync-every" in args else 64
nocache = "--no-nocache" not in args
capture = args[args.index("--capture") + 1] if "--capture" in args else None
d = os.path.join(root, "stall-%d" % os.getpid()); os.mkdir(d)
CH = 1 << 20; F_NOCACHE = 48; t0 = time.time()
lock = threading.Lock(); current = {}; calls = []; done = False

def timed(name, op, i, fn):
    start = time.time()
    with lock: current[name] = (op, i, start)
    fn()
    end = time.time()
    with lock:
        current[name] = ("idle", i, end)
        calls.append((name, op, i, start, end))

def writer(name):
    fd = os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    if nocache: fcntl.fcntl(fd, F_NOCACHE, 1)
    for i in range(mib):
        block = os.urandom(CH)
        timed(name, "write", i, lambda: os.write(fd, block))
        if fsync_every and i % fsync_every == fsync_every - 1:
            timed(name, "fullfsync", i, lambda: fcntl.fcntl(fd, fcntl.F_FULLFSYNC))
    timed(name, "fullfsync", mib, lambda: fcntl.fcntl(fd, fcntl.F_FULLFSYNC))
    os.close(fd)

def watchdog():
    fired = False
    while not done:
        time.sleep(0.25)
        now = time.time()
        with lock: snap = dict(current)
        stuck = [(n, v) for n, v in snap.items() if v[0] == "write" and now - v[2] >= 4.0]
        if stuck and not fired:
            fired = True
            print("[%7.2f] a write outstanding 4 s: %s" % (now - t0, ", ".join(
                "%s %s #%d for %.1f s" % (n, v[0], v[1], now - v[2]) for n, v in sorted(snap.items()))))
            sys.stdout.flush()
            if capture: subprocess.Popen(capture, shell=True)
        if not stuck: fired = False

threads = [threading.Thread(target=writer, args=("w%d" % i,)) for i in range(writers)]
w = threading.Thread(target=watchdog); w.start()
[t.start() for t in threads]; [t.join() for t in threads]
done = True; w.join(); total = time.time() - t0
print("%d writers x %d MiB, fsync every %s, nocache %s: %.1f s = %.1f MiB/s" % (
    writers, mib, fsync_every or "never", nocache, total, writers * mib / total))
long = sorted([c for c in calls if c[4] - c[3] >= 3.0 and c[1] == "write"], key=lambda c: c[3])
fs = [c for c in calls if c[1] == "fullfsync"]
print("fullfsync calls: %d, median %.0f ms, longest %.0f ms" % (
    len(fs), sorted(c[4] - c[3] for c in fs)[len(fs) // 2] * 1000, max(c[4] - c[3] for c in fs) * 1000))
ws = sorted(c[4] - c[3] for c in calls if c[1] == "write")
print("write calls: %d, median %.0f ms, p99 %.0f ms, longest %.0f ms" % (
    len(ws), ws[len(ws) // 2] * 1000, ws[len(ws) * 99 // 100] * 1000, ws[-1] * 1000))
for name, op, i, start, end in long:
    others = [c for c in calls if c[0] != name and c[3] < end and c[4] > start and c[4] - c[3] >= 0.5]
    print("[%7.2f - %7.2f] (%s - %s) %s %s #%d took %.2f s; meanwhile: %s" % (
        start - t0, end - t0, time.strftime("%H:%M:%S", time.localtime(start)),
        time.strftime("%H:%M:%S", time.localtime(end)), name, op, i, end - start,
        "; ".join("%s %s #%d %.2f-%.2f" % (c[0], c[1], c[2], c[3] - t0, c[4] - t0) for c in others) or
        "nothing else took 0.5 s"))
    # how many calls did the others complete during it
    if end - start >= 3.0:
        for other in sorted(set(c[0] for c in calls) - {name}):
            n = len([c for c in calls if c[0] == other and c[1] == "write" and c[3] >= start and c[4] <= end])
            print("            %s completed %d writes during it" % (other, n))
for n in os.listdir(d): os.unlink(os.path.join(d, n))
os.rmdir(d)
