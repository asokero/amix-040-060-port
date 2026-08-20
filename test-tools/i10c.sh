# i10c.sh -- ISSUE-10: introspect the GENESIS synchronously, at the one site that fires
# exactly once -- the wb040 drop-warning point (unresolved fault + valid pending WB3).
#
# WHY THIS SITE.  Every symbol-wrapper probe (as_fault, segvn_faultpage) kept catching
# adjacent faults.  wbf_dropwarn fires on precisely one thing -- a fault that came back
# unresolved with a valid pending write-back still in its 040 frame -- and on the wall
# wbf_dropped_n reached exactly 1: the genesis.  At that instant curproc is sh, the frame
# holds fa/WB3D/PC/SR/SSW, and sh's address space is walkable.  i10c (PART TEN) rides that
# same site and, once armed, reads the ground truth of why the first-touch write did not
# resolve.  Report-only: it does NOT change the outcome (still SIGSEGV / skipped replay).
#
# THE FORK IT SETTLES (read after the magic and i10c_latched):
#   i10c_seg / i10c_covered   does a segment COVER fa?  covered=1 with i10c_fa_covered=1
#                             (break past fa) => a DEMAND-ZERO corner (the page should have
#                             zero-filled and did not).  seg=0 / covered=0 => brk/grow had
#                             not extended the segment before sh wrote (a grow/coverage gap)
#   i10c_fa_covered           1 = fa < brkend (sh's break already reached this address)
#   i10c_brksize              SMALL here = the genesis is EARLY (tiny arena), refuting the
#                             late 16 MB grow-failure; LARGE = late
#   i10c_availrmem/freemem    plentiful = early; scarce = the memory-pressure story
#   i10c_wbrep                wb_replay_n so far -- small = few resolved store-faults = early
#   i10c_mmusr / i10c_ptpsr   ptest(fa): 0x400=I not present, 0x800=W wprot, 0=resident/rw
#   i10c_pte / i10c_ptev      leaf PTE + value at fa: 0 = truly absent
#   i10c_wb3d                 the dropped store value -- expect 0x800114B5 (sh's marker)
#   i10c_rw                   2 = S_WRITE (from SSW bit 8) -- the store direction
#
# WHERE THIS RUNS.  The install miniroot.  kpeek/kpoke are cross-built host-side and parked
# in the source disk's raw slice.  Bourne sh (backticks, no $(...), no [[ ]], no grep -q).
# It off-loads its log by dd-ing it into the raw slice.  ptest reuses i10r's real 040 ptestr
# (i10r_ptest_on ships 1, so no extra poke is needed).
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10c_magic at BOTH candidate bases:
# 0x07000000 (this rig) and 0x08000000.  The one that answers 49314321 ("I1C!") is live.
# The addresses below MOVE every build; refresh from
# `tools/status-facts.sh <kernel> 0x07000000`.  Values are the genesis-introspection kernel
# 68040-260820 series (built dormant; control rebuilds differ only in the build-id byte).
#
# Usage on the guest:  sh /i10c.sh   (writes /i10c.log, publishes it at slice-5 1 KiB
#                                     block 25792 -- reusing the retired i10a slot)

LOG=/i10c.log

# --- base 0x07000000 (this rig) ---
IC=0710DD40		# i10c_magic
ICON=0710DD44		# i10c_on  (the ARM flag)
ICLAT=0710DD4C		# i10c_latched
# --- base 0x08000000 (accelerator; +0x01000000) ---
IC8=0810DD40
ICON8=0810DD44

exec > $LOG 2>&1

echo I10C-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /i10t.sh /i10t.log /i10r.sh /i10r.log /i10s.sh /i10s.log /i10a.sh /i10a.log /i10b.sh /i10b.log /x.sh /l.txt /m.txt /w.txt /irl.txt /isl.txt /iar.txt /ibl.txt /icl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10c_magic must read 49314321 (I1C!) at the live base ---"
echo "base 0x07:"
/kpeek $IC 1
echo "base 0x08:"
/kpeek $IC8 1
sync

echo "--- BEFORE: the i10c block (magic first; on/latched must be 0) ---"
/kpeek $IC 37
sync

echo "--- ARM: i10c_on 0 -> 1 (both bases).  Latches the FIRST unresolved-fault-with-WB3 ---"
/kpoke $ICON 0 1
/kpoke $ICON8 0 1
echo "KPOKE i10c_on rc=$?"
/kpeek $IC 37
sync

# MOUNT READ-ONLY (mflag 1): a rw mount of this s5 payload slice fails ENOSPC on any image
# whose slice 4 was previously mounted rw and never unmounted.  i10c only reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the i10c block, 37 longs (the genesis fa/segment/brk/ptest state) ---"
/kpeek $IC 37
sync

/kpeek $ICLAT 1 > /icl.txt
if grep '= 00000001' /icl.txt > /dev/null 2>&1; then
	echo "--- LATCHED the genesis: read i10c_covered / i10c_fa_covered / i10c_seg / i10c_ret above ---"
else
	echo "--- did NOT latch: no unresolved-fault-with-valid-WB3 occurred (check wbf_dropped_n) ---"
fi
sync

echo I10C-END
sync
sync

# publish the log into the raw slice.  Block 25792 is the retired i10a slot (i10a was the
# inconclusive as_fault probe); 25664-25775 hold earlier scripts, 25824 holds i10b, and
# 25856+ holds a /bin/sh copy -- none is written over.
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25792
sync
sync
echo I10C-PUBLISHED > /dev/console
