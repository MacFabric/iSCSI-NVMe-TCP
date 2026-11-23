#!/usr/bin/python3
"""What a hypervisor would meet on an attached disk's device node.

    raw-device-check.py /dev/rdiskN      OVERWRITES the first MiB of the disk.

Opens the node as whoever runs it, tries writes a guest's virtual disk would
and would not send, and asks for a flush each way a raw-device client can.
Whether a flush reached the extension is in its log: the `flushes=` count on
its CLOSE and unmount lines (subsystem me.herko.iSCSIInitiator.fsext)."""
import errno, fcntl, mmap, os, struct, sys, time
dev = sys.argv[1]
DKIOCSYNCHRONIZECACHE = 0x20006416      # _IO('d', 22)
DKIOCSYNCHRONIZE = 0x80186416           # _IOW('d', 22, dk_synchronize_t)
DKIOCGETBLOCKSIZE = 0x40046418          # _IOR('d', 24, uint32_t)
DKIOCGETFEATURES = 0x4004644c           # _IOR('d', 76, uint32_t)
info = os.stat(dev)
print("%s: owner %d, mode %o, opened as uid %d" % (dev, info.st_uid, info.st_mode & 0o777, os.getuid()))
fd = os.open(dev, os.O_RDWR)
aligned = mmap.mmap(-1, 1 << 20); aligned.write(os.urandom(1 << 20))
def attempt(what, call):
    start = time.time()
    try:
        call(); print("%-44s ok (%.1f ms)" % (what, (time.time() - start) * 1000))
    except OSError as e:
        print("%-44s %s" % (what, errno.errorcode.get(e.errno, e.errno)))
attempt("pwrite 1 MiB, page-aligned buffer", lambda: os.pwrite(fd, aligned, 0))
attempt("pwrite 4096 bytes, unaligned buffer", lambda: os.pwrite(fd, b"x" + os.urandom(4095), 0))
attempt("pwrite 1000 bytes (not whole blocks)", lambda: os.pwrite(fd, os.urandom(1000), 0))
attempt("pwrite 512 bytes at offset 100", lambda: os.pwrite(fd, os.urandom(512), 100))
attempt("fsync", lambda: os.fsync(fd))
attempt("F_FULLFSYNC", lambda: fcntl.fcntl(fd, fcntl.F_FULLFSYNC))
attempt("DKIOCSYNCHRONIZECACHE", lambda: fcntl.ioctl(fd, DKIOCSYNCHRONIZECACHE))
attempt("DKIOCSYNCHRONIZE, whole disk", lambda: fcntl.ioctl(fd, DKIOCSYNCHRONIZE, struct.pack("QQII", 0, 0, 0, 0)))
print("block size %d" % struct.unpack("I", fcntl.ioctl(fd, DKIOCGETBLOCKSIZE, b"\0" * 4))[0])
print("features 0x%x (1 FUA, 2 barrier, 4 priority, 0x10 unmap)"
      % struct.unpack("I", fcntl.ioctl(fd, DKIOCGETFEATURES, b"\0" * 4))[0])
os.close(fd)
