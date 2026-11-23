#!/usr/bin/python3
"""Three writers on a raw device, each in its own region, every call timed.
    write-stall-raw.py /dev/rdiskN <MiB per writer> <writers>     DESTROYS what is on the device."""
import mmap, os, sys, threading, time
dev, mib, writers = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
CH = 1 << 20; t0 = time.time(); calls = []; lock = threading.Lock()
def writer(n):
    fd = os.open(dev, os.O_WRONLY)
    m = mmap.mmap(-1, CH); m.write(os.urandom(CH))
    base = (1 + n) << 30
    for i in range(mib):
        s = time.time(); os.pwrite(fd, m, base + i * CH); e = time.time()
        with lock: calls.append((n, s, e))
    os.close(fd)
ts = [threading.Thread(target=writer, args=(n,)) for n in range(writers)]
[t.start() for t in ts]; [t.join() for t in ts]; total = time.time() - t0
ws = sorted(e - s for n, s, e in calls)
print("%d writers x %d MiB on %s: %.1f s = %.1f MiB/s" % (writers, mib, dev, total, writers * mib / total))
print("write calls: %d, median %.0f ms, p99 %.0f ms, longest %.0f ms; of 3 s or more: %d" % (
    len(ws), ws[len(ws)//2]*1000, ws[len(ws)*99//100]*1000, ws[-1]*1000, len([w for w in ws if w >= 3])))
