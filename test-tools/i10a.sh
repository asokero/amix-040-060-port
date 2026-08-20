# i10a.sh -- ISSUE-10: audit as_fault's DECISION on the marker write, so "no segment
# covers it" (brk didn't grow) vs "segment there but lookup misses" reads directly.
#
# WHAT IS BEING AUDITED.  i10s (PART SEVEN) armed on the VA and was decisive: the wall
# fired (BUS ERROR 4AFC0003 flood) but i10s_vamatch_n = 0 with i10s_seen_n = 663 --
# the marker WRITE at 0x800152A0 NEVER reaches segvn_faultpage.  The per-page
# protection restorer is exonerated.  The refusal is one level UP, in as_fault: it
# calls as_segat, and a NULL return takes as_fault's `moveq #3` (FC_NOMAP = 3), which
# u_trap maps to SEGV_MAPERR (i10r's sicode 1).  sh's own "no space" is setbrk
# reporting brk() failed, so the arena GROW / segment machinery is implicated.
# i10a (PART EIGHT) hooks as_fault and records the as_segat result and the process
# break extent for the watched write.
#
# HOW TO READ THE CAPTURE (magic first, then i10a_latched -- with latched = 0 every
# field below it is ship-time state):
#   i10a_vamatch_n did the write reach as_fault at all (should be > 0: i10s proved it
#                  does not reach segvn, but it MUST reach as_fault -- that is where the
#                  refusal is)
#   i10a_seg       as_segat BEFORE resolution: 0 = NO covering segment (the FC_NOMAP
#                  cause); nonzero = a seg was found -> read segbase/segsize
#   i10a_segbase/segsize  if a seg was found: s_base + s_size <= addr means it is TOO
#                  SHORT to cover the address (a gap), distinct from no segment at all
#   i10a_seg_post  as_segat AFTER: did a covering segment appear during resolution?
#   i10a_ret       as_fault's ACTUAL return: 3 = FC_NOMAP (expected), 0 = resolved
#   i10a_type      1 = F_INVAL demand, 2 = F_PROT
#   i10a_brkbase / i10a_brksize / i10a_brkend   the process break as brk keeps it:
#                  brkend = brkbase + brksize.  brkend < addr = the break never reached
#                  the write (brk did not grow / failed -- hypothesis i / iii); brkend
#                  >= addr with i10a_seg = 0 = brk's bookkeeping grew but the segment
#                  lookup does not cover it (hypothesis ii)
#   i10a_as / i10a_pas   the address space as_fault got vs the proc's p_as (must agree)
#
# THE KEY IS THE VA, NOT THE PROCESS (the i10s lesson): a proc pointer is a table slot
# the wall's sh lands in differently each boot, so i10a arms on the VA and leaves the
# proc filter OFF (watchproc = 0 = any proc).  This run pokes watchproc = 0.
#
# WHAT i10a CANNOT PERTURB.  It hooks as_fault, forwards every call to the stock body
# (as_fault_orig) unchanged, and only on the ONE matched write fault calls as_segat
# (a pure lookup) around the resolution.  It reads only kernel structs.  It does not
# touch i10g_on/i10w_on/i10r_watchva/i10s_watchva -- all stay 0.
#
# WHERE THIS RUNS.  The install miniroot.  kpeek/kpoke are cross-built host-side and
# parked in the free tail of the source disk's raw slice, so the first thing here is a
# pair of dd's.  Bourne sh for the guest (backticks, no $(...), no [[ ]], no grep -q).
# It off-loads its log by dd-ing it back into the source disk's raw slice.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10a_magic at BOTH candidate bases:
# 0x07000000 (this rig) and 0x08000000.  The one that answers 49314121 ("I1A!") is the
# live block.  The addresses below MOVE every build; refresh from
# `tools/status-facts.sh <kernel> 0x07000000`.  Values are the as_fault-audit kernel
# 68040-260820 series (built dormant; control rebuilds differ only in the build-id byte).
#
# Usage on the guest:  sh /i10a.sh   (writes /i10a.log, publishes it at slice-5
#                                     1 KiB block 25792)

LOG=/i10a.log

# --- base 0x07000000 (this rig) ---
IA=0710DD74		# i10a_magic
IAPROC=0710DD78		# i10a_watchproc  (filter: leave 0 = any proc)
IAWVA=0710DD7C		# i10a_watchva    (the ARM gate)
IAMASK=0710DD80		# i10a_watchmask
IARW=0710DD84		# i10a_watchrw
IAVAM=0710DD90		# i10a_vamatch_n
IALAT=0710DD98		# i10a_latched
IARET=0710DDD0		# i10a_ret
# --- base 0x08000000 (accelerator; +0x01000000) ---
IA8=0810DD74
IAPROC8=0810DD78
IAWVA8=0810DD7C
IAMASK8=0810DD80

# The marker write vanishes at user 0x800152A0 (page 0x80015000).  Pass 1 aims the
# PAGE (mask fffff000, per the aim spec); pass 2 tightens to the EXACT address if pass
# 1 caught an innocent RESOLVED write (i10a_ret = 0) or did not latch.  VA is the
# stable key -- NOT a proc.
WVA=80015000
EXACT=800152A0
MASK=fffff000

exec > $LOG 2>&1

echo I10A-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /i10t.sh /i10t.log /i10r.sh /i10r.log /i10s.sh /i10s.log /x.sh /l.txt /m.txt /w.txt /irl.txt /isl.txt /iar.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10a_magic must read 49314121 (I1A!) at the live base ---"
echo "base 0x07:"
/kpeek $IA 1
echo "base 0x08:"
/kpeek $IA8 1
sync

echo "--- BEFORE: the i10a block (magic first; watchva/latched must be 0) ---"
/kpeek $IA 31
sync

echo "--- ARM (both bases): watchva 0 -> $WVA is the arm; proc filter OFF ---"
# The ARM poke is watchva.  watchproc is forced to 0 (any process): a proc pointer is a
# table slot the wall's sh lands in differently each boot.  watchmask/watchrw are
# re-poked to their shipped defaults so the aim is self-documenting.
/kpoke $IAPROC 0 0
/kpoke $IAPROC8 0 0
echo "KPOKE i10a_watchproc=0 (any proc) rc=$?"
/kpoke $IAMASK $MASK $MASK
/kpoke $IAMASK8 $MASK $MASK
echo "KPOKE i10a_watchmask rc=$?"
/kpoke $IAWVA 0 $WVA
/kpoke $IAWVA8 0 $WVA
echo "KPOKE i10a_watchva 0 -> $WVA (ARM) rc=$?"
/kpeek $IA 31
sync

# MOUNT READ-ONLY (mflag 1): a rw mount of this s5 payload slice fails ENOSPC on any
# image whose slice 4 was previously mounted rw and never unmounted.  The audit reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER (pass 1, page-aimed): the i10a block, 31 longs ---"
/kpeek $IA 31
sync

# PASS 2: tighten to the EXACT marker-write address if pass 1 caught an innocent
# RESOLVED write (i10a_ret = 0) or never latched.  The exact address is sh's specific
# bloktop, unlikely to be hit by any other process, so it isolates the failing write.
NEED2=y
/kpeek $IALAT 1 > /iar.txt
if grep '= 00000001' /iar.txt > /dev/null 2>&1; then
	/kpeek $IARET 1 > /iar.txt
	if grep '= 00000000' /iar.txt > /dev/null 2>&1; then
		echo "--- pass 1 latched a RESOLVED write (ret=0): re-aim exact and retry ---"
	else
		echo "--- pass 1 latched a FAILING write (ret != 0): the bug -- no pass 2 ---"
		NEED2=n
	fi
else
	echo "--- pass 1 did NOT latch: re-aim exact and retry ---"
fi
if [ $NEED2 = y ]; then
	/kpoke $IALAT 1 0
	echo "KPOKE i10a_latched -> 0 (re-arm) rc=$?"
	/kpoke $IAMASK $MASK ffffffff
	/kpoke $IAMASK8 $MASK ffffffff
	echo "KPOKE i10a_watchmask -> ffffffff (exact) rc=$?"
	/kpoke $IAWVA $WVA $EXACT
	/kpoke $IAWVA8 $WVA $EXACT
	echo "KPOKE i10a_watchva -> $EXACT rc=$?"
	/kpeek $IA 31
	sync
	echo "--- THE WALL again, exact-aimed ---"
	sh -n /cdrom/install/bin/setup.sh
	echo "WALL2 rc=$?"
	sync
	echo "--- AFTER (pass 2, exact): the i10a block, 31 longs ---"
	/kpeek $IA 31
fi
sync

echo I10A-END
sync
sync

# publish the log into the raw slice.  Block 25792 is free; 25664-25775 hold earlier
# scripts/i10r/i10s, and 25856+ holds a /bin/sh copy -- neither is written over.
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25792
sync
sync
echo I10A-PUBLISHED > /dev/console
