#!/usr/bin/python3
"""Mixed read/write load with verification, for a mounted volume.

    mixed-load.py <directory> <MiB per file> <files>

Four phases over <files> files of <MiB per file> each, one thread per file:
write alone, read alone, read the first set while writing a second, read both
sets. Reads and writes bypass the buffer cache (F_NOCACHE) so both reach the
device at the same time, every read is checked against a SHA-256 of what was
written, and each thread reports its longest single call. Works in its own
mixed-<pid> directory and removes it. docs/open-questions.md item 21."""
import fcntl, hashlib, os, sys, threading, time
root = sys.argv[1]; mib = int(sys.argv[2]); nfiles = int(sys.argv[3])
d = os.path.join(root, "mixed-%d" % os.getpid()); os.mkdir(d)
CH = 1 << 20; F_NOCACHE = 48
lock = threading.Lock(); errors = []; stats = {}

def write(name):
    h = hashlib.sha256(); t = time.time(); slow = 0.0
    fd = os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    fcntl.fcntl(fd, F_NOCACHE, 1)
    for i in range(mib):
        b = os.urandom(CH); h.update(b); t0 = time.time(); os.write(fd, b)
        slow = max(slow, time.time() - t0)
        if i % 64 == 63: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    fcntl.fcntl(fd, fcntl.F_FULLFSYNC); os.close(fd)
    with lock: stats["w " + name] = (mib / (time.time() - t), slow)
    return h.hexdigest()

def read(name, want, label):
    h = hashlib.sha256(); t = time.time(); slow = 0.0; n = 0
    fd = os.open(os.path.join(d, name), os.O_RDONLY); fcntl.fcntl(fd, F_NOCACHE, 1)
    while True:
        t0 = time.time(); b = os.read(fd, CH); slow = max(slow, time.time() - t0)
        if not b: break
        h.update(b); n += len(b)
    os.close(fd)
    ok = h.hexdigest() == want and n == mib * CH
    with lock:
        stats[label + " " + name] = (mib / (time.time() - t), slow)
        if not ok: errors.append("%s %s: MISMATCH (%d bytes)" % (label, name, n))

def run(fns):
    ts = [threading.Thread(target=f) for f in fns]; t = time.time()
    [x.start() for x in ts]; [x.join() for x in ts]; return time.time() - t

def report(title, took, total_mib):
    print("%s: %d MiB in %.1f s = %.1f MiB/s" % (title, total_mib, took, total_mib / took))
    for k in sorted(stats): print("   %-14s %7.1f MiB/s  longest call %.0f ms" % (k, stats[k][0], stats[k][1] * 1000))
    stats.clear(); sys.stdout.flush()

sums = {}
def w(name):
    def f(): sums[name] = write(name)
    return f
try:
    a = ["a%d" % i for i in range(nfiles)]; b = ["b%d" % i for i in range(nfiles)]
    report("1 write alone", run([w(n) for n in a]), mib * nfiles)
    report("2 read alone", run([lambda n=n: read(n, sums[n], "r") for n in a]), mib * nfiles)
    report("3 mixed: read a* while writing b*",
           run([lambda n=n: read(n, sums[n], "r") for n in a] + [w(n) for n in b]), 2 * mib * nfiles)
    report("4 mixed again: read b* while rewriting nothing, verify a* too",
           run([lambda n=n: read(n, sums[n], "r") for n in a + b]), 2 * mib * nfiles)
finally:
    for n in os.listdir(d): os.unlink(os.path.join(d, n))
    os.rmdir(d)
print("ERRORS: %s" % errors if errors else "all reads verified")
