#!/usr/bin/python3
"""Run mixed-load.py unchanged, but time every os.write/os.read/F_FULLFSYNC it makes, and when a
write has been outstanding for 4 s run a capture command once while it still is.
    write-stall-mixed.py <capture-cmd> <mixed-load.py args...>"""
import fcntl, os, subprocess, sys, threading, time
capture = sys.argv[1]; t0 = time.time()
lock = threading.Lock(); current = {}; calls = []
real_write, real_read, real_fcntl = os.write, os.read, fcntl.fcntl
def timed(op, fn):
    me = threading.current_thread().name; start = time.time()
    with lock: current[me] = (op, start)
    try: return fn()
    finally:
        end = time.time()
        with lock:
            current[me] = ("idle", end)
            if end - start >= 0.5: calls.append((me, op, start - t0, end - t0))
os.write = lambda fd, b: timed("write", lambda: real_write(fd, b))
os.read = lambda fd, n: timed("read", lambda: real_read(fd, n))
def patched_fcntl(fd, cmd, *a):
    if cmd == fcntl.F_FULLFSYNC: return timed("fullfsync", lambda: real_fcntl(fd, cmd, *a))
    return real_fcntl(fd, cmd, *a)
fcntl.fcntl = patched_fcntl
def watchdog():
    fired = False
    while True:
        time.sleep(0.25); now = time.time()
        with lock: snap = dict(current)
        stuck = [n for n, v in snap.items() if v[0] == "write" and now - v[1] >= 4.0]
        if stuck and not fired:
            fired = True
            print("[%7.2f] WRITE OUTSTANDING 4 s: %s" % (now - t0, ", ".join(
                "%s %s for %.1f s" % (n, v[0], now - v[1]) for n, v in sorted(snap.items()))), flush=True)
            subprocess.Popen(capture.replace("%T", "%d" % now), shell=True)
        if not stuck: fired = False
threading.Thread(target=watchdog, daemon=True).start()
sys.argv = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "mixed-load.py")] + sys.argv[2:]
try:
    exec(compile(open(sys.argv[0]).read(), sys.argv[0], "exec"), {"__name__": "__main__"})
finally:
    print("calls of 3 s or more:")
    for me, op, s, e in sorted(calls, key=lambda c: c[2]):
        if e - s >= 3.0:
            others = ["%s %s %.1f-%.1f" % (c[0][-1:], c[1], c[2], c[3]) for c in calls
                      if c[0] != me and c[2] < e and c[3] > s and c[3] - c[2] >= 1.0]
            print("  [%7.2f - %7.2f] %s %s %.1f s | meanwhile >=1 s: %s" % (s, e, me, op, e - s, "; ".join(others)[:400]))
