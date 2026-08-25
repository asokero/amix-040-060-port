# i10probe.sh -- ISSUE-10: WHAT is the page the wall's bad pointer lives in?
# Bourne sh for the guest (AGENTS.md "Code that runs on AMIX itself"): backticks,
# no $(...), no [[ ]].  Companion to i10bench.sh, which measured the reverse-map
# give-up counters and refuted them; this one runs the capture that question left
# behind.
#
# WHERE THIS RUNS.  The same 68040 install miniroot as i10bench.sh -- a UFS root
# with /bin, /etc, /dev and nothing else.  kpeek is cross-built host-side and
# parked in the free tail of the source disk's raw slice, which is why the first
# real command is a dd: the miniroot has dd and chmod and no package manager.
#
# WHY IT STARTS BY DELETING THINGS.  The miniroot's root filesystem is ON DISK
# and survives reboots, so every previous run's droppings are still there.  That
# is not tidiness: the last session's second boot failed to reproduce anything
# because `mount` returned ENOSPC, and a root filled with an earlier run's 76 KB
# of truncated test scripts is the obvious way to arrive there.  A run that
# cannot mount its own source disk produces a page of zeroes that looks exactly
# like a measurement.
#
# WHAT IT MEASURES.  The i10p block (src/i10rev040.s), latched by i10p_probe from
# usrxmemflt's unresolved-fault tail.  Read BEFORE and AFTER the wall:
#   * before -- i10p_magic must be 49313050 ("I10P") and the three masks must
#     read f0000000 / 40000000 / ffff0000.  If the magic is wrong every other
#     number below is noise, and a stale address does not fail, it lies.
#   * after  -- i10p_n counts the band faults; i10p_have says whether a page was
#     found; everything after that is the page's identity and content.
#
# The block ends with six POINTER HANDLES (kvseg, segu, segkmap, pages,
# pages_base, pages_end).  Those are COMMON symbols the loader puts in .bss, so
# they have no address computable from the image; the handles hold their runtime
# addresses.  Read the handles here, then read what they point at with a second
# kpeek -- which is the step that says which kernel segment the constant belongs
# to, instead of measuring its distance from whichever symbol happens to be
# nearest below it.
#
# Kernel cmn_err output does NOT arrive in this log: NOTICE lines go to the
# console.  The console transcript and this file are both needed and neither
# substitutes for the other.
#
# HOW THE LOG GETS OFF THE MACHINE.  This rig has no network -- the a2065 is
# stripped, because the point of the rig is the 040 memory path and not the
# emulator's ethernet.  The last act is therefore to dd the log BACK into the
# raw slice, at a block the host knows, so the numbers can be read out of the
# disk image byte-exactly.  Reading ~110 hexadecimal values off console
# screenshots is how a probe like this quietly loses a digit.
#
# Usage on the guest:  sh /i10p.sh          (writes /i10p.log, publishes it at
#                                            slice-5 1 KiB block 25696)

LOG=/i10p.log
IP=0710BDA4
I10=0710BD8C

exec > $LOG 2>&1

echo I10P-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /x.sh /l.txt /m.txt /w.txt
sync

echo "--- stage kpeek out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
chmod 755 /kpeek
sync

echo "--- BEFORE: magic first, then the masks, then an idle block ---"
/kpeek $IP 58
/kpeek $I10 6
sync

# MOUNT READ-ONLY (mflag 1), and not because the probe is being polite.  A
# READ-WRITE mount of this s5 payload slice fails with ENOSPC on any image whose
# slice 4 was previously mounted rw and never unmounted -- which is every image
# a crashed or killed bench run leaves behind.  Read-only mounts the same slice
# cleanly on exactly that image, and the probe only ever reads.  Getting this
# wrong costs a whole run: the mount fails, setup.sh cannot be opened, and the
# log that comes back is a page of zeroes that looks just like a measurement.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER ---"
/kpeek $IP 58
/kpeek $I10 6
echo I10P-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25696
sync
sync
echo I10P-PUBLISHED > /dev/console
