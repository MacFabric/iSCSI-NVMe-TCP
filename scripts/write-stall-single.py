#!/usr/bin/python3
"""One measured writer against competing writers, with syncs issued on a schedule.

    write-stall-single.py <dir> <seconds> <mode> [--aligned] [--fsync-every N] [--competitors N]
              [--sync-every S] [--sync-priority default|background]

mode: append (the file grows) or overwrite (a 256 MiB file written first, then
rewritten in place, as a disk image is). --aligned writes from a page-aligned
buffer, which is what lets F_NOCACHE bypass the buffer cache. The competitors
append to files of their own, buffered, with F_FULLFSYNC every 64 MiB. Reports
the measured writer's calls of a second or more beside the syncs that overlap
them. Removes its own files."""
import fcntl, mmap, os, subprocess, sys, threading, time
a = sys.argv[1:]
def opt(name, default): return a[a.index(name) + 1] if name in a else default
root, seconds, mode = a[0], float(a[1]), a[2]
aligned = "--aligned" in a
fsync_every = int(opt("--fsync-every", "0")); competitors = int(opt("--competitors", "2"))
sync_every = float(opt("--sync-every", "0")); sync_priority = opt("--sync-priority", "background")
d = os.path.join(root, "stall2-%d" % os.getpid()); os.mkdir(d)
CH = 1 << 20; F_NOCACHE = 48; PRE = 256
t0 = time.time(); stop = False; calls = []; syncs = []; written = [0, 0]; rivals = []
made = threading.Semaphore(0)

def buffer():
    data = os.urandom(CH)
    if not aligned: return data
    m = mmap.mmap(-1, CH); m.write(data); return m

def measured():
    # Made after the competitors' files: the newest file is the one a sync
    # has been seen to hold longest.
    for _ in range(competitors): made.acquire()
    path = os.path.join(d, "measured")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    block = buffer()
    if mode == "overwrite":
        for _ in range(PRE): os.write(fd, os.urandom(CH))
        fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    fcntl.fcntl(fd, F_NOCACHE, 1)
    ready.set(); go.wait()
    i = 0
    while not stop:
        if mode == "overwrite": os.lseek(fd, (i % PRE) * CH, os.SEEK_SET)
        s = time.time(); os.write(fd, block); e = time.time()
        calls.append(("write", s - t0, e - t0)); written[0] += 1; i += 1
        if fsync_every and i % fsync_every == 0:
            s = time.time(); fcntl.fcntl(fd, fcntl.F_FULLFSYNC); e = time.time()
            calls.append(("fullfsync", s - t0, e - t0))
    os.close(fd)

def competitor(n):
    fd = os.open(os.path.join(d, "c%d" % n), os.O_WRONLY | os.O_CREAT, 0o600)
    fcntl.fcntl(fd, F_NOCACHE, 1)
    made.release()
    go.wait(); i = 0
    while not stop:
        block = os.urandom(CH)
        s = time.time(); os.write(fd, block); e = time.time()
        if e - s >= 1.0: rivals.append((n, s - t0, e - t0))
        written[1] += 1; i += 1
        if i % 64 == 0: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    os.close(fd)

def syncer():
    go.wait()
    cmd = ["/usr/sbin/taskpolicy", "-b", "/bin/sync"] if sync_priority == "background" else ["/bin/sync"]
    while not stop:
        time.sleep(sync_every)
        if stop: break
        s = time.time(); subprocess.call(cmd); e = time.time()
        syncs.append((s - t0, e - t0))

ready = threading.Event(); go = threading.Event()
threads = [threading.Thread(target=measured)] + [threading.Thread(target=competitor, args=(n,)) for n in range(competitors)]
if sync_every: threads.append(threading.Thread(target=syncer))
[t.start() for t in threads]; ready.wait()
t0 = time.time(); go.set(); time.sleep(seconds); stop = True; [t.join() for t in threads]
ws = sorted(e - s for op, s, e in calls if op == "write")
print("%s%s%s, %d competitors, sync %s: measured %.1f MiB/s, competitors %.1f MiB/s" % (
    mode, " aligned" if aligned else " unaligned", ", fsync every %d" % fsync_every if fsync_every else ", no fsync",
    competitors, ("every %g s at %s" % (sync_every, sync_priority)) if sync_every else "from launchd only",
    written[0] / seconds, written[1] / seconds))
print("   writes: %d, median %.0f ms, p99 %.0f ms, longest %.1f s; of 1 s or more: %d; of 3 s or more: %d" % (
    len(ws), ws[len(ws) // 2] * 1000, ws[len(ws) * 99 // 100] * 1000, ws[-1],
    len([w for w in ws if w >= 1]), len([w for w in ws if w >= 3])))
if syncs:
    ds = sorted(e - s for s, e in syncs)
    print("   syncs: %d, median %.1f s, longest %.1f s" % (len(ds), ds[len(ds) // 2], ds[-1]))
print("   competitors' writes of 3 s or more: %s" % (
    ", ".join("c%d %.1f s (%s)" % (n, e - s, time.strftime("%H:%M:%S", time.localtime(t0 + s)))
              for n, s, e in rivals if e - s >= 3.0) or "none"))
for op, s, e in calls:
    if e - s >= 2.0 and op == "write":
        over = ["sync %.1f-%.1f" % (ss, se) for ss, se in syncs if ss < e and se > s]
        print("   measured %s %.1f s, %s - %s" % (op, e - s, time.strftime("%H:%M:%S", time.localtime(t0 + s)),
                                              time.strftime("%H:%M:%S", time.localtime(t0 + e))))
print("   wall clock of t=0: %s" % time.strftime("%H:%M:%S", time.localtime(t0)))
for n in os.listdir(d): os.unlink(os.path.join(d, n))
os.rmdir(d)
