# i10cen.sh -- ISSUE-10: is the poisoned word a stray store into a CLEAN page
# (H2) or a fill that left the frame's upper half UNCLEANED (H1)?
#
# Companion to i10probe.sh, which found the page: one healthy, singly-mapped anon
# heap page of sh's arena (pfn 7623, user 0x80014000) holding exactly one wrong
# longword, 0x4AFC0000, at page offset 0xAA0 -- in the UPPER half of the 4 KiB
# frame.  That offset is what this run is about.  Every named 2 KiB-era tail-zero
# site (anon_zero, the swap-in klustsize "destructive tail zero", anon_getpage,
# the s5/ufs/spec file-getapage tails, segmap_pagecreate) is already converted to
# a full 0x1000 clear in this kernel, so:
#   * if the frame's upper half reads as sh's own arena (0x8001xxxx block links,
#     ASCII, and long runs of zero) with the one word as the sole anomaly, the
#     fill did its job and the word arrived by a mis-addressed WRITE -- H2;
#   * if the upper half is dense, foreign, zero-run-free content, a fill left the
#     tail uncleaned and the word is a prior owner's -- H1.
# i10p_probe now censuses the latched frame: i10p_nzlo / i10p_nzhi (non-zero longs
# per half), i10p_zrun (longest run of consecutive zero longs), and i10p_h0..h15
# (the 64-byte block that contains the hit).  The i10p block therefore grew from
# 58 longs to 77; read that many.
#
# Bourne sh for the guest (AGENTS.md "Code that runs on AMIX itself"): backticks,
# no $(...), no [[ ]].  Runs on the same 68040 install miniroot as i10probe.sh --
# a UFS root with /bin, /etc, /dev and nothing else -- and off-loads its log by
# dd-ing it back into the source disk's raw slice, this rig having no network.
#
# IP / I10 are the runtime addresses of i10p_magic and i10_magic for the kernel
# under test, from `tools/status-facts.sh <kernel> 0x07000000`.  They MOVE every
# build (this block sits in .data, which shifts by the size of any .text change),
# so a rebuild must refresh them; the values below are the 68040-260819 census
# kernel (i10rev040.s + the census loop).
#
# Usage on the guest:  sh /i10c.sh    (writes /i10c.log, publishes it at
#                                      slice-5 1 KiB block 25696)

LOG=/i10c.log
IP=0710BE94
I10=0710BE7C

exec > $LOG 2>&1

echo I10CEN-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /x.sh /l.txt /m.txt /w.txt
sync

echo "--- stage kpeek out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
chmod 755 /kpeek
sync

echo "--- BEFORE: magic first, then the masks and the idle census block ---"
/kpeek $IP 77
/kpeek $I10 6
sync

# MOUNT READ-ONLY (mflag 1): a read-write mount of this s5 payload slice fails
# with ENOSPC on any image whose slice 4 was previously mounted rw and never
# unmounted -- which is every image a crashed bench run leaves behind.  The probe
# only ever reads.  (i10probe.sh's header carries the full account.)
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the census fields (i10p_nzlo..i10p_h15) are the last 19 longs ---"
/kpeek $IP 77
/kpeek $I10 6
echo I10CEN-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25696
sync
sync
echo I10CEN-PUBLISHED > /dev/console
