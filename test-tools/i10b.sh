# i10b.sh -- ISSUE-10: confirm the arena GROW fails at brk -> as_map -> hat_sdtalloc,
# the root cause behind the FC_NOMAP write fault i10a placed in as_fault.
#
# WHAT IS BEING CONFIRMED.  i10s exonerated the per-page check; i10a placed the marker
# write's refusal in as_fault (as_segat finds no covering segment -> FC_NOMAP).  The
# synthesis is that the data-segment grow itself fails one step earlier: brk -> as_map
# -> hat_map -> hat_growsdt -> hat_sdtalloc "not enough contiguous memory for segment
# tables" (68040 4 KiB-page pressure), so the segment is never extended and the later
# write finds nothing.  sh's own "no space" is setbrk reporting brk() failed.  i10b
# (PART NINE) catches the FIRST brk whose grow FAILS and records brk's numbers plus the
# contiguous-memory shortfall the ISSUE-39 counters already track.
#
# WHY THE HOOK IS GUARANTEED LIVE (the i10a lesson).  The kernel is ET_REL: brk (0x580e8)
# has exactly ONE reference -- the sysent dispatch slot -- so weakening brk and providing
# a strong wrapper re-binds that one slot and intercepts every brk syscall with no bypass.
#
# HOW TO READ (magic first, then i10b_latched -- 0 = nothing caught, every field below
# is ship-time):
#   i10b_ret         brk's return: 12 = ENOMEM (the grow failed), 0 = ok
#   i10b_newbrk      the requested new break (a heap addr whose page covers 0x800152A0)
#   i10b_brkbase / i10b_brksize_pre / i10b_brksize_post   the break before and after:
#                    brksize_post == brksize_pre = the grow did NOT advance the break
#   i10b_brkend_pre  p_brkbase + p_brksize = the break end before the grow.  If this is
#                    below 0x800152A0, the break never covered the write -- which is why
#                    as_segat found no segment (i10a's FC_NOMAP)
#   i10b_sdtfail_pre / i10b_sdtfail_post   hat_sdtfail_n before and after: a non-zero
#                    DELTA means hat_sdtalloc's "not enough contiguous memory" path fired
#                    for THIS grow -- the segment-table shortfall, named directly
#   i10b_availrmem / i10b_freemem   the memory state at the failing grow
#   i10b_fail_n      brk calls that returned non-zero (grow-fail or early reject)
#
# SAFETY-NET CROSS-CHECK.  The wb040 safety net (wbf_dropwarn) is now in the kernel, so
# running the wall ALSO increments wbf_dropped_n (the WBF! block) and prints the
# "unresolved fault dropped a pending write-back" NOTICE for the same dropped store.
# This script dumps the WBF! block too: wbf_dropped_n > 0 is the write-side of the bug,
# i10b is the grow-side -- two ends of one defect.
#
# WHERE THIS RUNS.  The install miniroot.  kpeek/kpoke are cross-built host-side and
# parked in the source disk's raw slice.  Bourne sh for the guest (backticks, no $(...),
# no [[ ]], no grep -q).  It off-loads its log by dd-ing it back into the raw slice.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10b_magic at BOTH candidate bases:
# 0x07000000 (this rig) and 0x08000000.  The one that answers 49314221 ("I1B!") is live.
# The addresses below MOVE every build; refresh from
# `tools/status-facts.sh <kernel> 0x07000000`.  Values are the grow-probe kernel
# 68040-260820 series (built dormant; control rebuilds differ only in the build-id byte).
#
# Usage on the guest:  sh /i10b.sh   (writes /i10b.log, publishes it at slice-5
#                                     1 KiB block 25824)

LOG=/i10b.log

# --- base 0x07000000 (this rig) ---
IB=0710DCE4		# i10b_magic
IBON=0710DCE8		# i10b_on  (the ARM flag)
IBLAT=0710DCF4		# i10b_latched
WBF=0710CD90		# wbf_magic (the safety-net counter block)
# --- base 0x08000000 (accelerator; +0x01000000) ---
IB8=0810DCE4
IBON8=0810DCE8

exec > $LOG 2>&1

echo I10B-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /i10t.sh /i10t.log /i10r.sh /i10r.log /i10s.sh /i10s.log /i10a.sh /i10a.log /x.sh /l.txt /m.txt /w.txt /irl.txt /isl.txt /iar.txt /ibl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10b_magic must read 49314221 (I1B!) at the live base ---"
echo "base 0x07:"
/kpeek $IB 1
echo "base 0x08:"
/kpeek $IB8 1
sync

echo "--- BEFORE: the i10b block (magic first; on/latched must be 0) ---"
/kpeek $IB 23
echo "--- BEFORE: the WBF! safety-net block (wbf_dropped_n must be 0) ---"
/kpeek $WBF 27
sync

echo "--- ARM: i10b_on 0 -> 1 (both bases).  No VA/proc filter: first FAILING brk grow ---"
/kpoke $IBON 0 1
/kpoke $IBON8 0 1
echo "KPOKE i10b_on rc=$?"
/kpeek $IB 23
sync

# MOUNT READ-ONLY (mflag 1): a rw mount of this s5 payload slice fails ENOSPC on any
# image whose slice 4 was previously mounted rw and never unmounted.  i10b only reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the i10b block, 23 longs (i10b_latched, i10b_ret, brk numbers, sdtfail) ---"
/kpeek $IB 23
echo "--- AFTER: the WBF! safety-net block (wbf_dropped_n = the write-side drop count) ---"
/kpeek $WBF 27
sync

# If the first failing brk was NOT the wall's grow (e.g. an unrelated ENOMEM), i10b_latched
# stays 0 only if NO grow failed at all; otherwise it caught the first.  Re-running is not
# useful here (one-shot on the first failing grow); a second boot would be needed to re-arm.
/kpeek $IBLAT 1 > /ibl.txt
if grep '= 00000001' /ibl.txt > /dev/null 2>&1; then
	echo "--- LATCHED a failing grow: read i10b_ret / i10b_sdtfail_* above ---"
else
	echo "--- did NOT latch: no brk grow failed in this parse (see i10b_fail_n / i10b_seen_n) ---"
fi
sync

echo I10B-END
sync
sync

# publish the log into the raw slice.  Block 25824 is free; 25664-25807 hold earlier
# scripts, and 25856+ holds a /bin/sh copy -- neither is written over.
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25824
sync
sync
echo I10B-PUBLISHED > /dev/console
