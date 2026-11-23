#!/usr/bin/python3
"""Flush one volume on a schedule, at this process's own (normal) priority.

    write-stall-flusher.py <volume path> <interval seconds> [wait]

Calls sync_volume_np on the volume every <interval>; with `wait`, asks it to
wait for the writes (SYNC_VOLUME_WAIT). Prints each flush's start and
duration. Runs until killed."""
import ctypes, sys, time
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
path = sys.argv[1].encode(); interval = float(sys.argv[2])
flags = 0x02 if len(sys.argv) > 3 and sys.argv[3] == "wait" else 0
while True:
    time.sleep(interval)
    s = time.time(); r = libc.sync_volume_np(path, flags); e = time.time()
    print("flush %s %.2f s%s" % (time.strftime("%H:%M:%S", time.localtime(s)), e - s,
                                 "" if r == 0 else " errno %d" % ctypes.get_errno()), flush=True)
