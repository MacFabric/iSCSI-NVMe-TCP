#!/usr/bin/python3
"""Boot a Linux guest in QEMU (emulated CPU) on one virtual disk and time its writes.

    write-stall-guest.py <label> <disk: image file or /dev/rdiskN> <MiB> [extra -drive options]

Wants, beside it, `qemu/qemu-system-aarch64` with its dylibs in `qemu/lib`
(Homebrew's, copied with what `otool -L` names outside /usr/lib and /System),
and `alpine/vmlinuz-virt` and `alpine/initramfs-virt` from Alpine's aarch64
netboot release. A macOS guest has no hypervisor, so this emulates the
processor (TCG); the disk path is QEMU's ordinary one, default cache mode.

The guest is Alpine's netboot kernel with a shell as init: it writes <MiB> to
/dev/vda in 4 MiB direct writes of random data, timing each from inside the
guest. DESTROYS what is on the disk. Prints throughput, the longest write and
every write of a second or more, with when it started (seconds into the run)."""
import os, subprocess, sys, threading, time
label, disk, mib = sys.argv[1], sys.argv[2], int(sys.argv[3])
extra = "," + sys.argv[4] if len(sys.argv) > 4 else ""
here = os.path.dirname(os.path.abspath(__file__))
env = dict(os.environ, DYLD_LIBRARY_PATH=here + "/qemu/lib")
cmd = [here + "/qemu/qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a72", "-accel", "tcg,thread=multi",
       "-smp", "2", "-m", "512", "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "stdio",
       "-kernel", here + "/alpine/vmlinuz-virt", "-initrd", here + "/alpine/initramfs-virt",
       "-append", "console=ttyAMA0 rdinit=/bin/sh quiet",
       "-drive", "if=none,id=d0,format=raw,file=" + disk + extra, "-device", "virtio-blk-pci,drive=d0"]
q = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
out = []; seen = threading.Condition()
def reader():
    while True:
        c = os.read(q.stdout.fileno(), 4096)
        if not c: break
        with seen: out.append(c.decode("latin-1")); seen.notify_all()
threading.Thread(target=reader, daemon=True).start()
def wait(marker, timeout):
    end = time.time() + timeout
    with seen:
        while marker not in "".join(out):
            left = end - time.time()
            if left <= 0 or q.poll() is not None:
                q.kill()
                sys.exit("%s: no %r from the guest; tail: %r" % (label, marker, "".join(out)[-800:]))
            seen.wait(min(left, 1))
def send(line): q.stdin.write((line + "\n").encode()); q.stdin.flush()
# Markers are written split in the shell (RE""ADY) so the terminal's echo of the command
# line cannot match them.
t0 = time.time()
wait("job control turned off", 240); boot = time.time() - t0
send("/bin/busybox --install -s 2>/dev/null; mkdir -p /proc /sys /dev /tmp; mount -t proc p /proc; mount -t sysfs s /sys; "
     "mount -t devtmpfs d /dev; mount -t tmpfs t /tmp; for m in virtio_pci virtio_blk; do modprobe $m 2>/dev/null; done; "
     "sleep 2; echo SIZE=$(cat /sys/block/vda/size 2>&1) RE\"\"ADY")
wait("READY", 90)
send("dd if=/dev/urandom of=/tmp/r bs=1M count=32 2>/dev/null; echo SEE\"\"DED")
wait("SEEDED", 180)
n = mib // 4
send("i=0; read s _ < /proc/uptime; while [ $i -lt %d ]; do read a _ < /proc/uptime; "
     "dd if=/tmp/r of=/dev/vda bs=4M count=1 skip=$((i%%8)) seek=$i oflag=direct conv=notrunc 2>/tmp/err || { echo WRITE-ERR\"\"OR $i $(cat /tmp/err); }; "
     "read b _ < /proc/uptime; echo $i $a $b >> /tmp/log; i=$((i+1)); done; read e _ < /proc/uptime; "
     "awk -v s=$s -v e=$e '{d=$3-$2; if(d>m)m=d; if(d>=1){l=l sprintf(\" %%.1f@%%.0f\",d,$2-s)}; if(d>=3)c++} "
     "END{printf \"RESU\" \"LT %%.1f MiB/s, longest write %%.2f s, of 3 s or more: %%d; of 1 s or more (s@when):%%s\\n\", NR*4/(e-s), m, c+0, l}' /tmp/log; "
     "dmesg | grep -iE 'I/O error|timeout|hung|blk_update' | tail -5; echo FINI\"\"SHED" % n)
started = time.strftime("%H:%M:%S")
wait("FINISHED", mib / 2 + 900)
for line in "".join(out).replace("\r", "").split("\n"):
    line = line.strip()
    if line.startswith(("RESULT", "WRITE-ERROR")) or (line.startswith("[") and "dmesg" not in line):
        print("%s [%s, guest up in %.0f s]: %s" % (label, started, boot, line.replace("RESULT ", "")))
q.kill()
