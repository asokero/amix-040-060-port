# i10s.sh -- ISSUE-10: audit the segvn_faultpage DECISION on the one write fault
# whose demand-fill fails, so "protection vs coverage" can be read rather than inferred.
#
# WHAT IS BEING AUDITED.  PART SIX (i10r) proved the marker write fault (fa
# 0x800152A0) is F_INVAL demand (branch 3), that as_fault(F_INVAL, S_WRITE) returned
# NONZERO, that usrxmemflt returned SIGSEGV code 1 (SEGV_MAPERR), and that the pending
# store was then dropped.  The same record shows the SAME absent page's later READ
# fault (rw=R) maps and zero-fills it: two faults of one class on one page, differing
# only in rw -- S_WRITE dies, S_READ lives.  i10r cannot see inside segvn by design.
# PART SEVEN (i10s) is the instrument doc 16.4/16.6 named: an OUTER wrapper on
# segvn_faultpage that records, for the watched VA + rw, exactly what the per-page
# protection restorer (segvn_prot040) is handed and what it is about to decide.
#
# THE KEY IS THE VA, NOT THE PROCESS.  The first bench run keyed on curproc =
# 0x4013BE00 -- PID 9's proc-table slot from an earlier i10r run -- and never matched
# this boot's wall-sh (PID 40, a different slot): a proc pointer is not stable across
# boots.  So i10s now ARMS on the VA (i10s_watchva) and leaves the proc filter OFF
# (i10s_watchproc = 0 = any process).  The 0x800152A0 write is specific to the
# arena-growing sh, so VA + rw is the stable key.  This run pokes watchproc = 0.
#
# DECISIVE EITHER WAY.  i10s_vamatch_n counts VA+rw matches REGARDLESS of proc:
#   * vamatch_n > 0 and latched -> the fault reached segvn_faultpage; read the
#     decision (protection vs coverage) below;
#   * vamatch_n == 0 while the wall demonstrably fired (BUS ERROR flood, I10S-END)
#     -> the fatal write NEVER reaches segvn_faultpage: as_fault fails UPSTREAM in
#     the segment lookup (consistent with SEGV_MAPERR = no segment covers the
#     address), and the next probe targets as_fault / as_segat.
#
# WHAT i10s CANNOT PERTURB.  It hooks the segvn_faultpage wrapper directly and reads
# only kernel structs (the seg, its segvn_data, the vpage, curproc, the u-area).  It
# write-protects nothing, single-steps nothing, needs neither i10g_on nor i10w_on nor
# i10r_watchva -- all stay 0.  The audited fault is the ordinary fault the wall takes.
# The ONLY arming poke is i10s_watchva.
#
# HOW TO READ THE CAPTURE (magic first, then i10s_latched -- with latched = 0 every
# field below it is ship-time state and says nothing about any fault):
#   i10s_vamatch_n did the write reach segvn_faultpage at all (see DECISIVE above)
#   i10s_pageprot  svd->pageprot.  0 = the per-page path is NOT entered, so the
#                  wrapper passes through and any refusal is segment-wide (read
#                  i10s_prot) or downstream in anon.  Nonzero = per-page active
#   i10s_prot      svd->prot, segment-wide protection.  bit1 (value 2) = WRITE
#   i10s_vpage     the vpage pointer for this page (0 = no per-page array)
#   i10s_vpprot    vp_prot: the vpage byte's TOP nibble; lacking bit1 = WRITE denial
#   i10s_protchk   the PROT_* mask for this rw (S_WRITE -> 2)
#   i10s_andval    vp_prot & protchk; 0 => the per-page check would deny
#   i10s_fcprot    1 = segvn_prot040 WILL return FC_PROT (per-page denial); 0 = pass
#   i10s_retval    4 = FC_PROT, -1 = falls through (verdict decided downstream)
#   i10s_svd0..15  the first 64 bytes of segvn_data, for OFFLINE anon-map / vpage-
#                  coverage decode against the headers (no offset is guessed on-box)
#
# THE CROSS-CHECK.  segvn_prot040 keeps its own counters (SVN! block).  If
# i10s_fcprot latched 1, segvn_prot_n must have incremented and segvn_prot_last_addr
# must equal i10s_addr.  Both blocks are dumped below.
#
# WHERE THIS RUNS.  The install miniroot -- a UFS root with /bin, /etc, /dev and
# nothing else.  kpeek/kpoke are cross-built host-side and parked in the free tail
# of the source disk's raw slice, so the first thing here is a pair of dd's, not a
# copy.  Bourne sh for the guest (AGENTS.md "Code that runs on AMIX itself"):
# backticks, no $(...), no [[ ]], no `grep -q`.  It off-loads its log by dd-ing it
# back into the source disk's raw slice, this rig having no network.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10s_magic at BOTH candidate bases:
# the A3000 motherboard base 0x07000000 (this rig) and the accelerator base
# 0x08000000.  The one that answers i10s_magic = 49315321 ("I1S!") is the live
# block.  The addresses below MOVE every build (the block sits in .data, which
# shifts with any .text change), so a rebuild must refresh them from
# `tools/status-facts.sh <kernel> 0x07000000`; the values are the decision-audit
# kernel 68040-260820 series with i10s_vamatch_n added (built dormant; byte-identical
# control rebuilds differ only in the build-id sequence byte).
#
# Usage on the guest:  sh /i10s.sh   (writes /i10s.log, publishes it at slice-5
#                                     1 KiB block 25760)

LOG=/i10s.log

# --- base 0x07000000 (this rig) ---
IS=0710D5E8		# i10s_magic
ISPROC=0710D5EC		# i10s_watchproc  (filter: leave 0 = any proc)
ISWVA=0710D5F0		# i10s_watchva    (the ARM gate)
ISMASK=0710D5F4		# i10s_watchmask
ISRW=0710D5F8		# i10s_watchrw
ISVAM=0710D604		# i10s_vamatch_n
ISLAT=0710D608		# i10s_latched
SVN=0710C8E8		# segvn_prot_magic (the wrapper's own counters)
# --- base 0x08000000 (accelerator; +0x01000000) ---
IS8=0810D5E8
ISPROC8=0810D5EC
ISWVA8=0810D5F0
ISMASK8=0810D5F4
SVN8=0810C8E8

# The page the marker write vanishes in: 0x800152A0 lies in page 0x80015000, and
# the audit gates on (addr & MASK) == WVA.  This is the stable key -- NOT a proc.
WVA=80015000
MASK=fffff000

exec > $LOG 2>&1

echo I10S-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /i10t.sh /i10t.log /i10r.sh /i10r.log /x.sh /l.txt /m.txt /w.txt /irl.txt /isl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10s_magic must read 49315321 (I1S!) at the live base ---"
echo "base 0x07:"
/kpeek $IS 1
echo "base 0x08:"
/kpeek $IS8 1
sync

echo "--- BEFORE: the i10s block (magic first; watchva/latched must be 0) ---"
/kpeek $IS 46
echo "--- BEFORE: the segvn_prot SVN! block (pp_n / n / last_addr / last_prot) ---"
/kpeek $SVN 5
sync

echo "--- ARM the audit (both bases): watchva 0 -> $WVA is the arm; proc filter OFF ---"
# The ARM poke is watchva.  watchproc is forced to 0 (any process): a proc pointer
# is a table slot the wall's sh lands in DIFFERENTLY each boot, so keying on it
# matches nothing across boots.  watchmask/watchrw are re-poked to their shipped
# defaults so the aim is self-documenting.  i10g_on, i10w_on and i10r_watchva all
# stay 0: no page is protected and the audited fault is the ordinary one.
/kpoke $ISPROC 0 0
/kpoke $ISPROC8 0 0
echo "KPOKE i10s_watchproc=0 (any proc) rc=$?"
/kpoke $ISMASK $MASK $MASK
/kpoke $ISMASK8 $MASK $MASK
echo "KPOKE i10s_watchmask rc=$?"
/kpoke $ISWVA 0 $WVA
/kpoke $ISWVA8 0 $WVA
echo "KPOKE i10s_watchva 0 -> $WVA (ARM) rc=$?"
/kpeek $IS 46
sync

# MOUNT READ-ONLY (mflag 1): a read-write mount of this s5 payload slice fails with
# ENOSPC on any image whose slice 4 was previously mounted rw and never unmounted --
# which is every image a crashed bench run leaves behind.  The audit only ever reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER (pass 1): the i10s block, 46 longs ---"
/kpeek $IS 46
echo "--- AFTER: the segvn_prot SVN! block (cross-check i10s_fcprot vs segvn_prot_n) ---"
/kpeek $SVN 5
sync

# PASS 2, only if pass 1 never latched.  vamatch_n tells the two failure kinds apart:
# a latch means we have the decision; no latch with vamatch_n > 0 means a proc filter
# rejected it (should not happen here -- filter is off); no latch with vamatch_n == 0
# means the write never reached segvn_faultpage.  Re-running the wall in the same boot
# is deliberate: a second parse costs less than a second boot.
/kpeek $ISLAT 1 > /isl.txt
if grep '= 00000001' /isl.txt > /dev/null 2>&1; then
	echo "--- pass 1 LATCHED: no second pass needed ---"
else
	echo "--- pass 1 did NOT latch: vamatch_n below says reached-VA vs never-reached ---"
	/kpeek $ISVAM 1
	echo "--- THE WALL again ---"
	sh -n /cdrom/install/bin/setup.sh
	echo "WALL2 rc=$?"
	sync
	echo "--- AFTER (pass 2): the i10s block, 46 longs ---"
	/kpeek $IS 46
	echo "--- AFTER (pass 2): the segvn_prot SVN! block ---"
	/kpeek $SVN 5
fi
sync

echo I10S-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly.  Block 25760
# is free; 25664-25735 hold earlier scripts/i10r, and 25856+ holds a /bin/sh copy --
# neither is written over.
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25760
sync
sync
echo I10S-PUBLISHED > /dev/console
