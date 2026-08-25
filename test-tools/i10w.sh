# i10w.sh -- ISSUE-10: NAME the instruction that stores 0x4AFC0000 into sh's
# arena at user 0x80014AA0, and say whether it is a USER store or a KERNEL one.
#
# Companion to i10cen.sh, which proved the poisoned frame is cleanly zero-filled
# so the bad word is a STORE, not a fill-tail or a page-lifetime defect.  A store
# of one longword into an otherwise clean, valid page cannot be found by scanning
# frames; it has to be caught AS IT LANDS.  i10w_hook (src/i10rev040.s) does that
# by write-protecting the target page and reading the format-7 access-error frame
# of every store into it -- so this driver's job is only to ARM the watch and read
# the block back.
#
# Bourne sh for the guest (AGENTS.md "Code that runs on AMIX itself"): backticks,
# no $(...), no [[ ]].  Same 68040 install miniroot as i10cen.sh -- a UFS root
# with /bin, /etc, /dev and nothing else -- and it off-loads its log by dd-ing it
# back into the source disk's raw slice, this rig having no network.
#
# THE ARM IS A kpoke.  i10w_on ships 0 so the watch is inert through the whole
# boot; this driver flips it to 1 with kpoke (through /dev/mem, the same device
# kpeek reads) immediately before the wall, so the FIRST process to demand-zero
# the target page after that -- the wall's own sh -- is the one that gets armed.
# i10w_armproc is read back so it can be checked against the wall's curproc.
#
# IW / IWON are the runtime addresses of i10w_magic and i10w_on for the kernel
# under test, from `tools/status-facts.sh <kernel> 0x07000000`.  They MOVE every
# build (the block sits in .data, which shifts by the size of any .text change),
# so a rebuild must refresh them; the values below are the 68040-260819 write-
# watch kernel (i10rev040.s with i10w_hook).
#
# Usage on the guest:  sh /i10w.sh    (writes /i10w.log, publishes it at
#                                      slice-5 1 KiB block 25696)

LOG=/i10w.log
IW=0710C264
IWON=0710C268
IP=0710C130

exec > $LOG 2>&1

echo I10W-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /x.sh /l.txt /m.txt /w.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BEFORE: the i10w block (magic must be 49315721, on/armed/latch all 0) ---"
/kpeek $IW 59
sync

# MOUNT READ-ONLY (mflag 1): a read-write mount of this s5 payload slice fails
# with ENOSPC on any image whose slice 4 was previously mounted rw and never
# unmounted -- which is every image a crashed bench run leaves behind.  The probe
# only ever reads.  (i10probe.sh's header carries the full account.)
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- ARM: kpoke i10w_on 0 -> 1 (the next demand-zero of 0x80014000 arms) ---"
/kpoke $IWON 0 1
echo "KPOKE rc=$?"
/kpeek $IW 59
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the capture (i10w) and the read-side page identity (i10p) ---"
/kpeek $IW 59
/kpeek $IP 77
echo I10W-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25696
sync
sync
echo I10W-PUBLISHED > /dev/console
