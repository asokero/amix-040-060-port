# i10s.sh -- ISSUE-10: audit the segvn_faultpage DECISION on the one write fault
# whose demand-fill fails, so "protection vs coverage" can be read rather than inferred.
#
# WHAT IS BEING AUDITED.  PART SIX (i10r) proved the marker write fault (fa
# 0x800152A0, proc 0x4013BE00) is F_INVAL demand (branch 3), that
# as_fault(F_INVAL, S_WRITE) returned NONZERO, that usrxmemflt returned SIGSEGV
# code 1 (SEGV_MAPERR), and that the pending store was then dropped.  The same
# record shows the SAME absent page's later READ fault (rw=R) maps and zero-fills
# it: two faults of one class on one page, differing only in rw -- S_WRITE dies,
# S_READ lives.  i10r cannot see inside segvn by design.  PART SEVEN (i10s) is the
# instrument doc 16.4/16.6 named: an OUTER wrapper on segvn_faultpage that records,
# for this proc+VA+rw, exactly what the per-page protection restorer (segvn_prot040)
# is handed and what it is about to decide -- protection or coverage.
#
# WHAT i10s CANNOT PERTURB.  It hooks the segvn_faultpage wrapper directly and
# reads only kernel structs (the seg, its segvn_data, the vpage, curproc, the
# u-area).  It write-protects nothing, single-steps nothing, needs neither i10g_on
# nor i10w_on nor i10r_watchva -- all stay 0.  The audited fault is the ordinary
# fault the uninstrumented wall takes.  The ONLY pokes are the process, address and
# mask to watch.
#
# HOW TO READ THE CAPTURE (magic first, then i10s_latched -- with latched = 0 every
# field below it is ship-time state and says nothing about any fault):
#   i10s_pageprot  svd->pageprot.  0 = the per-page path is NOT entered, so the
#                  wrapper passes straight through and any refusal is segment-wide
#                  (read i10s_prot) or downstream in anon.  Nonzero = per-page
#                  protections are active and vp_prot below is the deciding value
#   i10s_prot      svd->prot, the segment-wide protection.  bit1 (value 2) = WRITE:
#                  if this is 3 (R|W) or 7 (R|W|X) the segment admits writes and the
#                  refusal is NOT a segment protection refusal
#   i10s_vpage     the vpage pointer for this page (0 = no per-page array)
#   i10s_vpprot    vp_prot: the vpage byte's TOP nibble.  Lacking bit1 (no 2) is a
#                  per-page WRITE denial; 0 can also mean the array does not cover
#                  this page (compare i10s_segbase/segsize to place the index)
#   i10s_protchk   the PROT_* mask for this rw (S_WRITE -> 2)
#   i10s_andval    vp_prot & protchk; 0 => the per-page check would deny
#   i10s_fcprot    1 = segvn_prot040 WILL return FC_PROT for this fault (per-page
#                  denial); 0 = it passes through to segvn_faultpage_orig
#   i10s_retval    4 = FC_PROT, -1 = falls through (verdict decided downstream)
#   i10s_svd0..15  the first 64 bytes of segvn_data, for OFFLINE anon-map / vpage-
#                  coverage decode against the headers (no offset is guessed on-box)
#
# THE CROSS-CHECK.  segvn_prot040 keeps its own counters (SVN! block).  If
# i10s_fcprot latched 1, segvn_prot_n must have incremented and segvn_prot_last_addr
# must equal i10s_addr -- the same decision, one predicted by i10s and one recorded
# by the code that makes it.  Both blocks are dumped below.
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
# kernel 68040-260820 series (built dormant; byte-identical control rebuilds differ
# only in the build-id sequence byte).
#
# Usage on the guest:  sh /i10s.sh   (writes /i10s.log, publishes it at slice-5
#                                     1 KiB block 25760)

LOG=/i10s.log

# --- base 0x07000000 (this rig) ---
IS=0710D5E0		# i10s_magic
ISPROC=0710D5E4		# i10s_watchproc
ISWVA=0710D5E8		# i10s_watchva
ISMASK=0710D5EC		# i10s_watchmask
ISRW=0710D5F0		# i10s_watchrw
ISLAT=0710D5FC		# i10s_latched
SVN=0710C8E0		# segvn_prot_magic (the wrapper's own counters)
# --- base 0x08000000 (accelerator; +0x01000000) ---
IS8=0810D5E0
ISPROC8=0810D5E4
ISWVA8=0810D5E8
ISMASK8=0810D5EC
SVN8=0810C8E0

# The wall's sh, measured emulator-side on this exact script and disk across the
# i10r/i10g/i10w/i10t runs: the process is DETERMINISTIC on this rig at 0x4013BE00
# (a fixed miniroot boot ordering hands the wall's sh the same proc slot every run).
WATCHPROC=4013BE00
# The page the marker write vanishes in: 0x800152A0 lies in page 0x80015000, and
# the audit gates on (addr & MASK) == WVA.
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

echo "--- BEFORE: the i10s block (magic first; watchproc/latched must be 0) ---"
/kpeek $IS 45
echo "--- BEFORE: the segvn_prot SVN! block (pp_n / n / last_addr / last_prot) ---"
/kpeek $SVN 5
sync

echo "--- ARM the audit (both bases): watchproc 0 -> $WATCHPROC, watchva/mask set ---"
# The arming poke is watchproc; watchva/mask are set explicitly to their shipped
# defaults so the aim is self-documenting and survives a moved default.  i10g_on,
# i10w_on and i10r_watchva all stay 0: no page is protected and the audited fault
# is the ordinary one the uninstrumented wall takes.
/kpoke $ISPROC 0 $WATCHPROC
/kpoke $ISPROC8 0 $WATCHPROC
echo "KPOKE i10s_watchproc rc=$?"
/kpoke $ISWVA $WVA $WVA
/kpoke $ISWVA8 $WVA $WVA
echo "KPOKE i10s_watchva rc=$?"
/kpoke $ISMASK $MASK $MASK
/kpoke $ISMASK8 $MASK $MASK
echo "KPOKE i10s_watchmask rc=$?"
/kpeek $IS 45
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

echo "--- AFTER (pass 1, page-aimed): the i10s block, 45 longs ---"
/kpeek $IS 45
echo "--- AFTER: the segvn_prot SVN! block (cross-check i10s_fcprot vs segvn_prot_n) ---"
/kpeek $SVN 5
sync

# PASS 2, only if pass 1 never latched.  The watched page is one process's bloktop,
# and a run whose arena grows differently might never present a WRITE fault in it.
# Widening to WHICHEVER access class comes first (watchrw 2 -> 0 does not exist; the
# rw knob has no "any", so instead re-run: the first pass already page-masked, so a
# miss means the write did not reach segvn_faultpage in this parse).  Re-running in
# the same boot is deliberate: a second parse costs less than a second boot.
/kpeek $ISLAT 1 > /isl.txt
if grep '= 00000001' /isl.txt > /dev/null 2>&1; then
	echo "--- pass 1 LATCHED: no second pass needed ---"
else
	echo "--- pass 1 did NOT latch: re-run the wall once more, same aim ---"
	echo "--- THE WALL again ---"
	sh -n /cdrom/install/bin/setup.sh
	echo "WALL2 rc=$?"
	sync
	echo "--- AFTER (pass 2): the i10s block, 45 longs ---"
	/kpeek $IS 45
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
